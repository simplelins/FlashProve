# 10 · CPU+FPGA 实施纲领：FlashProve 证明器的 FPGA 部署路线

> 目标：**Llama 4 Maverick 全尺寸证明在 CPU+FPGA 上跑通**（ASIC 为最终形态）。
> 前置：全链路已在 4090 打通（见 09 号报告）；FPGA 目标平台 = ZCU/U55C 级 HBM 板卡
> （你的 DeepProve FPGA 文档口径，~460 GB/s HBM）；**本机无 Vivado/板卡** —— 本机承担
> 金标准、仿真验证与 RTL 开发，整体交付到 FPGA 机。

---

## 1. 环境判定（2026-11-07 实测）

| 项 | 状态 |
|---|---|
| 本机 Vivado/HLS | **无**（/home/share 路径是 DeepProve 开发机的） |
| 本机 FPGA 卡 | **无**（lspci 无 Xilinx/Alveo） |
| 本机仿真器 | **verilator + iverilog ✓**（RTL 可本机仿真验证） |
| 金标准向量 | **已生成**：`probes/hash_vectors.txt`（57 行官方 KAT，H/TH 全覆盖）+ `format_hash.py`/`blake2b_f.py`（纯 stdlib 参考实现）|
| 目标平台 | ZCU/U55C 级：HBM ~460 GB/s，BRAM ~数十 MB，PCIe Gen4 |
| 协同金标准 | sm89-port 分支（bit-exact 软件参考 + 全部块级单测） |

## 2. 部署批次（每批 = 可独立验证的交付物）

### 批次 A：BLAKE2b 压缩核 + 树构建器（M1 核心）
- **RTL**：12 轮流水 compress（8×8 G 函数全展开），接口 = 128B 块入 / 64B 摘要出；
  上层：leaf/node/vertex 三种 tag 模式（对应 hash.h 的 leaf_end/node/vertex）；
- **Testbench**：`hash_vectors.txt` 57 行 KAT + `two_digests` 结构对拍（label‖l‖r 布局，
  hash.h:454-464）；
- **验收**：Verilator 仿真全过 → FPGA 机上板实测吞吐 → **目标：commit 哈希吞吐 ≥ 100 GB/s**
  （对照 GPU 实测 ~15 GB/s；39 min commit 的哈希主导段 → 压至 ~5 min）。
- **✅ 进展（2026-11-12，WP1.1 压缩函数核完成）**：`fpga/rtl/blake2b_f.v`（迭代核，~98 周期/块）
  + `fpga/rtl/blake2b_comb.v`（组合参考实现，always@(*) 循环式）双实现均 **512/512 KAT 通过**
  （`fpga/vectors/f_kat.txt`，源自 verifier/tests/known_answers/blake2b_f.py 的 made_up()）。
  三个真实 bug 与定位法（对后续 WP 的教训）：
  1. **对角四元组不是 (k, k+5, k+10, k+15) mod 16**——正确是 4×4 矩阵转置
     (k, 4+(k+1)%4, 8+(k+2)%4, 12+(k+3)%4)，即 (0,5,10,15)(1,6,11,12)(2,7,8,13)(3,4,9,14)；
     自然 mod-16 回绕把 k=2,3 的 b/c 送错到 12,13/0,1,2（应为 8,9/12,13,14）；
  2. **对角步的消息字索引用全步编号** sigma[2*sub]（sub=0..7），不是半段内编号 2*s4——
     否则 G4–G7 读 sigma[0..7] 而非 sigma[8..15]；
  3. **打包 sigma 常量一行错**：sel[4] 的 FA 应为 AF（σ[4][6]=10, σ[4][7]=15 被对调）。
  定位法：组合参考实现先过 KAT（隔离 TB 接线）→ Python 逐步复刻 RTL + 挂钩 G 逐调用对拍
  → 第一个分歧调用反推参数（暴力搜索 m 对/四元组/旋转组合，锁定 m=(15,10) 换位）。
  剩余：树构建器（leaf/node/vertex tag 模式）+ Verilator lint + hash_vectors.txt 57 行对拍。

### 批次 B：Goldilocks 域 ALU + sumcheck 折叠单元
- 域乘 p=2^64−2^32+1（约减只需 2^64≡2^32−1 的两次移位加）；E=X³−2 三字元素（K3）；
- sumcheck 折叠：eq 张量乘 + 求和（对照 `psc_layer_test` 的 17 case 作 RTL testbench）；
- **验收**：与 CPU 逐值 bit-exact。

### 批次 C：查表森林引擎
- packed 表（131 KB）常驻 BRAM/URAM（U55C HBM 备用）；直方图（count_keys16 语义）；
- **验收**：`forest_lookup_test` 的 10 组（**含我们新加的 PACKED 组**）作为 RTL 对拍集。

### 批次 D：系统集成
- PCIe DMA 框架 + FS 链主机协同（轮次粒度消息传递，blocks typed-rounds 为接口规范）；
- 权重流（464 GB/批 ÷ Gen4 ~32 GB/s ≈ 15 s，占比可忽略）；
- **红线**：trace slab 与 folded row 必须常驻板卡 HBM（轮间依赖，禁止 PCIe 往返）。

## 3. 本机即做清单（无需 FPGA 机）
1. Verilator testbench 骨架（读 hash_vectors.txt 的 C++/Python 驱动）——**金标准已就位**；
2. ~~compress 的纯 Verilog~~ **✅ 已完成**（blake2b_f.v + blake2b_comb.v，512/512 KAT，见批次 A）；
3. `psc_layer_test` 17 case 转储为域 ALU 的 RTL 对拍向量；
4. 目录：`fpga/`（RTL/tb/vectors/docs）建议放 `sm89-port` 分支或独立仓。**✅ 已建**（fpga/rtl, tb, vectors, bench）。

## 4. ASIC 衔接（最终形态）
- 批次 A/B/C 的 RTL 即 ASIC 的**微架构规格**（工艺无关）；
- ASIC 增量 = 大 SRAM（数百 MB，消除全部 shared 预算墙：k_ws 59K/k_stored 214K/Tile4 130K/
  count_keys16 128K/PackedSrc 131K——移植解剖的完整清单见 09 报告）+ HBM 32 GB+
  （folded row 9.7 GB + slab + kept 层）+ 多流水线堆叠；
- 物理门槛：BLAKE2b 引擎 ~120 GB/s→200+ GB/s 仅需流水堆叠（面积几 mm²）；域 ALU 同理。

## 5. 风险与纪律
- **串行 FS 链**：轮间挑战依赖 → 链上做哈希或轮粒度往返（先数 Plan 轮次）；
- **差分测试义务**：FPGA 证明 = "not the released programs"，一切以 cp_verify/Lean
  验证器接受为准；块级 bit-exact 先行；
- **秘密纪律**：bring-up 走 `-public-weights`（maverick 路线），秘密模式最后。

---
*2026-11-07 · 前置：09 号移植报告（全链路 YES）；金标准与探针在 `zk-bootcamp/probes/`。*

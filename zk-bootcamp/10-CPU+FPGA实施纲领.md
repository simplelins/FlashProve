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
- **✅ 进展（2026-11-12，H 链引擎完成）**：`fpga/rtl/h_chain.v`——format 的 H/hp 引擎
  （128B 块 F 链接：首态 IV⊕0x01010040；每块 t_lo = 4L（末块）否则 128(b+1)，hp 的顶点
  索引 x 置入 t_lo 位 32–63；t_hi = {L, num}；末块 last 标志）。**44/44 通过
  hash_vectors.txt 的 H 行**（含 L=70001＝2188 块链式 291k 周期、num=2³¹+3）。
  两个新坑（记录在案）：① 块地址必须 b·2⁵ + rd[4:0]——rd 是 6 位（含装填排空值 32），
  直接拼接会把排空值漏进地址，第 2 块起全部哈错；② Icarus 的 $sscanf 转换数上限 <16，
  KAT 文件须转成逐 token 格式（fpga/vectors/hash_kat.txt，由 hash_vectors.txt 派生）。
  TH 树哈希（th_chain.v，双区换位 + 10/11 双号分层）已就位，小向量 6/6，全量在跑。
- **✅ 进展（2026-11-12 续，批次 A 哈希核全部完成）**：
  - `th_chain.v` **13/13 TH 向量通过**（含 L=1000001：5 层树、4.47M 周期；128 字/片 10 号、
    摘要层 11 号、双存储区逐级换位）；
  - `str_hash.v` **58/58 mode_vectors.txt 全通过**——blocks/hash/hash.h 的通用串哈希引擎
    （begin64 初态：IV⊕param0⊕Start 于 salt/person 槽；t_hi=0；末块 t_lo=total；
    每块 16 个 64 位字），覆盖全部域：Merkle 叶（W 符号 + 40..64B 盐 + fill）、链标签、
    顶点、2⁶³ 索引、2⁴⁸ 树号、32/64 字节摘要。**即 leaf/node/vertex 三种 tag 模式的核心
    已就位**，剩顶点树控制器（two_digests 一拍压缩 + 树结构调度）为批次 A 收尾。
  - 转换器三大教训（已写进 KAT 文件头）：mode_vectors 的 digest/start 是**字节串**，
    须按小端装 u32（hash.h 的 d.w[i]）；mode 的 total 含 16 字节 label；
    H/TH 的 digest 是 u32 状态字直打（两种约定不同！）。
  - TB 教训：Icarus 的 @(*) 看不见函数内部读的信号（需显式敏感表）；$fscanf 不能以
    part-select 为目标；64 字节摘要需 16 项期望数组。

### 批次 B：Goldilocks 域 ALU + sumcheck 折叠单元
- 域乘 p=2^64−2^32+1（约减只需 2^64≡2^32−1 的两次移位加）；E=X³−2 三字元素（K3）；
- sumcheck 折叠：eq 张量乘 + 求和（对照 `psc_layer_test` 的 17 case 作 RTL testbench）；
- **验收**：与 CPU 逐值 bit-exact。
- **✅ 进展（2026-11-12，域 ALU 完成）**：`fpga/rtl/gf_alu.v` 四模块全组合——
  gf_add64/gf_sub64（一次条件减 p）、gf_mul64（核心恒等式：a·b = lo + h1·2⁹⁶ + h0·2⁶⁴
  ≡ lo + (h0<<32) − h0 − h1 (mod p)，由 2⁶⁴≡2³²−1 与 2⁹⁶≡−1；一次 +p 抬升负值、
  一次折叠 + 单次条件减 p 即归约完成，无需循环）、gf3_mul（9 个 gf_mul64 + 7 个 gf_add64
  按 vf_common.h Ex 公式拼装）。**726/726 KAT 通过**（`fpga/vectors/gf_kat.txt`：边界
  0/1/p−1/2³²/2⁶³ 双序 + 650 随机，期望值由纯 Python mod-p 与多项式 mod x³−2 生成，
  语义与实现无关）。TB 用逐 token $fscanf（Icarus 的 $sscanf 转换数上限 <9；
  $fgets 右对齐，行首字符在 [8*sc−1 −: 8]——两个仿真器坑记录在 TB 注释里）。

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

## 6. L2-alt 实测日志（2026-11-12，进行中）

### 已走通的路径（scales/ 完整管线，全部在 48GB 4090 D 上）
1. **make_model**（prover/tests/weights_blocks/）生成合成 GGUF：形状行
   `L=48 H=40 G=8 f=16384 fe=8192 NE=32 V=202048 seed=2026`（≈106G 参数，61GB q8 类 GGUF，
   与 Maverick 同为 0.5B/参数量级）。D=5120 与 DH=128 硬编码在 make_model 里；
   参数界：layers 1–1023, H/G 2–510, f/fe 256–65280, NE 0–1023, V ≤ 2^24。
2. **calibrate.py --device cuda**（Python 3.13 venv，requirements.txt 哈希锁定）：
   3 窗口 × 64 token 秒级完成 → words.json（313 maxima）。
3. **words_to_policy.py**：BASE policy 只需改形状行（NE/fe/L/V），转换器另搬 6 行 scales
   （eps1_lo/eps2_lo/MF/KF/epsF_lo/s——注意 s 15→18：来自拟合，非 Maverick 常数）。
4. **cp_verify -plan arrays（exit 4=接受）→ pack_layout.py（2565 行 F + 25 行 E）→
   -plan accounting（PLAN ONLY）**——configuration digest `5a71a86a…`。

### policy 形状的三个硬约束（血泪教训，各吃掉一轮 make_model+calibrate）
1. **MoE 层要求 f = 2·fe 且 fe 为 2 的幂**（cp_verify.cpp:494 shape-words）——fe=4096 配
   f=16384 直接被拒；
2. **H 子证明调用形状下限**：`c.n = lJ + lt ≥ max(10, nminH, la=16)`（cp_verify.cpp:1807），
   而 lJ 随层数 L 与 V 缩——L 12、V 32768 都让 R16a 跌破下限。**结论：L 与 V 不可缩**
   （保持 48/202048），可缩的只有 fe/NE（专家维度）；
3. **table 行是容量不是精确值**（"makes room for the pads"）——保留全尺寸 table 行合法，
   commit 显存 ≈ 0.23×26GB（权重缓冲随参数缩）+ 22.3GB（表结构不变）≈ 28GB ✓ 48GB 卡可容。
   代价：commit 哈希段不随模型缩小（仍 ~39min 量级）。

### 环境重建（原 flashprove-exp 已删）
- CUDA 13.2.86：pip `cuda-toolkit[nvcc,cublas,cccl,crt,nvvm,cudart]==13.2.2` →
  `$HOME/cuda-13.2.86/nvidia/cu13/bin`（build.md 的 8 行法，TUNA 源）；
- g++13：`$HOME/gcc13bin` 符号链接（conda-forge 13.4.0），cp_verify 的 libstdc++ 经
  rpath 自解析（ldd 无 not found）✓；
- prover sm_89 构建：`FP_ARCH=sm_89 OUT=$W/build-hc prover/build.sh` ✓ exit 0；
- Python 3.13.13：`$HOME/usr/miniconda3/bin/python3.13`（现成）。

### 阻塞与看门狗
ComfyUI（PID 1942526）占 GPU 27.5GB——cp_commit 拒绝 >2GB 占用。已挂看门狗：
GPU 空闲（<2GB）即自动启动 `cp_commit -weights model -config config -M 1
-ivk ivk -isk isk -worst-case-table table.txt`，日志在 scales-mid/commit.log。
预期：worst-case FP64 检查 ~50min（3.78h × 0.23）+ 各阶段 ≈ 1.5–2.5h。

---
*2026-11-07 · 前置：09 号移植报告（全链路 YES）；金标准与探针在 `zk-bootcamp/probes/`。*

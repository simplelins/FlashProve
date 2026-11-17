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


## 7. L2-alt 达成（2026-11-15 04:00，全链路 YES）

**commitment ID `8d20b21ba0c806573a19125b30f5452c330e7f216d209141e0605bf7f0a3b9f3`** ——
RTX 4090 D 48GB（sm_89 移植版程序）上，scales/ 真实管线（校准 + 最坏情形检查 + e_res 10）
对一个 Llama-4 架构 MoE 模型（**L=24, d=5120, H=40, G=8, f=16384, fe=8192, NE=32,
V=202048 ≈ 53G 参数**，合成权重）完成 **cp_commit → cp_prove → cp_verify 全链路 YES**：

- `result-v1 status=0 bits=128 policy=exact-match record=1`；proof 10.5 MB，key.bin 2.1 MB；
- 覆盖：next-token 判定（r=1023, e=1024, T=1024），covered: y=yes；
- proof of work：32 bits 计入 59 轮，least round 128.00 bits（无 PoW 96.23 bits）；
- 时间：commit 75 分钟（worst-case FP64 检查 ~30 分钟——3.78h 全尺寸 × 23% 参数 × 折叠修正，
  实测与预测一致）、prove ~13 分钟、verify CPU 分钟级。

### 通往 YES 的四堵墙（每堵墙的根因与处置，按发现顺序）
1. **status 7（scales 过紧）**：worst_case.py 加粗 scales + **e_res 11→10**，wsums/fold 以
   新 eres 重做（weight_sums 不覆写 → 新文件夹 mv GGUF）。附带的坑：
   **worst_case.py 的 emb_bits 预测偏乐观 1 位**（预测 10，实测 12）——以 sums 文件的实测列
   为准修正 words.json；
2. **key-file 阶段 -gpu-memory 墙**：`HF_ONCE_ENGINE_ROOM = 24 GiB`（H100 编译期常数）+
   2 GiB 驱动预留 → slab 只许 16.2GB < 需求 18.55GB。处置：引擎 24→**23 GiB** +
   驱动预留 2→**1 GiB**（两个硬件适配常数，不改任何输出字节）+ `-piece-bytes 128MB`
   释放权重阶段残留——key-file 通过；
3. **entry 阶段墙（真正的死墙）**：entry 的折叠行**按设计是 key 的 2 倍**（hf_commit_once.cuh
   `for_tables = 2 * lent_bytes(...)`）→ 需求 30.65GB > 任何引擎预留组合。**折叠行 =
   27 × ell（与模型大小无关，纯 table 行驱动）**——106G 参数模型在 ell=402.6M 下无解；
4. **最终解**：模型减半（L=48→24）+ **table ell 402.6M→2^27（1.21× fi0 下限）**——
   entry 需求降到 ~18GB，一次通过。

### 对 L3/L4 的推论
- **48GB 卡的可承载规模**：该 table 行（2^27，fi0 的 1.21 倍）下 entry 墙在 ~30G 参数量级；
  更大的模型需要更大的 ell → entry 需求线性上升 → **50G+ 参数的 commit 需要 64GB+ 显存**；
- L3（真实 Maverick 4-bit，464G 参数）在此卡上不可行（full-size 需要 80GB H100，与移植
  报告结论一致），但 **scales 管线的每个 CPU 步骤已全部验证可用**，上 H100 即走；
- 脚本资产：scales-mid/{l2alt-round2.sh, round24.sh, round24-2.sh, round24-3.sh}——
  含 status-7 自动重试、e_res 变更自动 wsums 重做、emb_bits 实测修正的完整自动化。


## 8. 批次服务实测（2026-11-17 00:40，24/24 全 PASS）

commitment `8d20b21b…` 上的**批次服务首次实测**（一次 `-in/-out` 调用 = 一个批次）：

| 指标 | 实测 |
|---|---|
| 批次规模 | 24 请求（各 1024-token 不同窗口，覆盖 y）|
| **cp_prove 耗时** | **505 s（8.4 分钟）**——单请求独立跑 ~13 分钟；权重遍历被 24 请求摊销，**边际成本 ~21 s/请求** |
| 出证 | 24 证明 + 24 回答，0 failed |
| 验证 | **24 PASS / 0 FAIL**（逐一 cp_verify，CPU） |
| 磨损 | count.bin 90→136 字节（**+46 精确**，与容量公式吻合）|
| 叶容量 | 957,394 批（= r 44,040,191 ÷ 46 列/批），已用 2，余 957,392 |

**服务经济学结论**：权重遍历是固定成本，批内请求的边际成本极低——批次越大单证越便宜（上限 = slots 64）。磨损率 46 列/批 → 该承诺可服务 95.7 万批 ≈ 2300 万请求（按每批 24）。

**运维坑（程序的安全规则，按其指名方式处置）**：
1. `cp-isk`：isk（密钥）的祖先链必须"仅本人可写"——仓库目录组可写 → 程序拒绝；按其指名 `chmod go-w` 修复；
2. `cp-weights`：**isk.txt 的 weights 行记录 commit 时的权重路径**——移动权重目录后必须更新该行（操作员状态文件，非源码）；
3. `make_request.py` 吃**裸 32 位小端字文件**，不是 .npy（有 128 字节头会被当作 token 拒绝）。


## 9. ⑥ 整数模型服务 + 多 token 覆盖证明（2026-11-17 03:15，YES）

**第二个承诺 `63028a500e616dae7c7ad5cc08a93b846d2076f4c3bf46a80d5772d75652a8b5`**
（small_file 形状：L=4, d=5120, NE=16, V=2048, T=256；commit 仅 **29 秒**）上的完整服务闭环：

1. **vLLM 0.29.0 + integer_model 插件**服务该模型（GGUF 权重直读，greedy）；
2. prompt `[17,400,3]` → 整数模型贪心回复 **`[1500,1363,1832,600]`**（4 token）；
3. 组 own_choices 式请求（r=2, e=6，**覆盖全部 4 个回复 token**）；
4. cp_prove → cp_verify：**YES**，`covered: positions=2..5 tokens=3..6 policy=exact-match`。

**排障账本（每条都是工具链的坑）**：
- serve.sh 的 make_model 参数 H=2 与硬编码 D=5120 矛盾（H×dh≠d）→ 生成的 policy 被
  `shape-heads` 拒——**自洽形状（H×dh=d）的模型 + 自备 reference 五件套**才可承诺；
- flashinfer JIT（vLLM 采样算子）需要 **curand 头**（pip CUDA 13.2.86 缺）→ 从系统
  cuda-13.3 拷 curand*.h（纯头文件，无版本冲突）；
- flashinfer 的 ninja 硬编码 `-L lib64`（pip 工具链只有 lib/）→ `ln -s lib lib64`；
- vLLM 引擎启动需 **ninja**（venv pip 装）+ VLLM_API_KEY + reference 五件套
  （integer_model.json/policy/KL/wsums/fold）齐备；
- pytest 980 通过（2 失败 13 错误全是服务类测试缺 ninja 所致，修复后 2/2 过）。

**意义**：served 回复的多 token 覆盖证明打通——provider 用 vLLM 服务、FlashProve 证明
整数模型贪心回复的完整形态在 48GB 卡上闭环（本轮 commit 29 秒、prove ~5 分钟）。


## 10. ④ ncu 剖析：被程序的反注入设计阻断（2026-11-17，结论）

`cp_prove`/`cp_commit` 的自重启卫生机制（closed_front.h:121 `no-fresh-start`）：二次启动的
环境必须**严格缩减**——ncu 注入的剖析变量使二次启动看到更多环境项 → 程序按设计拒绝。
**外部 profiler 剖析 commit/prove 被安全设计阻断**（防篡改 дисципline 的一部分）。

替代的量化路径（已具备）：M-a/M-b 微基准 + 相位计时 + 20× 差距分析（§2）；
更深的内核级数字需要仓库自带的剖析设施或 CUDA Graph 内嵌计时——留作与上游沟通的项。


## 11. 批次 B 完成：FOLD 轮次引擎 bit-exact（2026-11-17）

`fpga/rtl/fold_round_comb.v` + `fpga/tb/tb_fold_round.v` + KAT（`gen_fold_kat.cpp` 直连
blocks/iop 权威实现生成）——**TB PASS，4 轮 + 终值全部 bit-exact**。

覆盖的语义（blocks/iop/fold_rounds.h FoldProverRounds + fold_algebra.h + hp.h）：
- **交错折叠**：`v'[i] = v[2i] + g·(v[2i+1] − v[2i])`（列主布局：entry c of row b at b + 2^a·c；
  相邻 flat 对 = 同列的行 2b, 2b+1）；
- **pair_products**：q(X) = ⟨a@X, m@X⟩ 的三个系数（每行对 a0·m0 + a0·m1 + a1·m0 + a1·m1）；
- **plain 权重的 moments = (2, 1, 1)**：phi(X⁰) = 0⁰ + 1⁰ = **2**（不是 1！）——after 递归里
  of_one() = 2 乘在后项上；phi(w_j) = 2·w_{j,0} + w_{j,1} + w_{j,2}，且**非末变量的 w_{j,0} = 0**
  （hp_place 无 t=0 槽）——wd 索引按变量分支；
- **end() 的缩放只乘 e.d**：e.mu = 未乘 eps·later 的原始折叠 mu（fold_rounds.h 的
  `for (K &x : e.d) x = x * s;`——曾误读为乘 e.mu）；
- **HidingPolynomial 的 round/bind**：q = w_i + before·psi_i + after_i；
  before = before·psi_i(g) + w_i(g)（非末变量 w_{j,0} = 0）。

至此批次 B 的三个原子（gf_alu 726/726 + hp_form 40/40 + fold_round 4/4 全轮）全部 bit-exact，
FPGA 路径覆盖 FOLD（承诺表的批量 sumcheck）的完整轮次计算。


## 12. 批次 C 环境就绪：森林查表的 10 组 KAT 已在 4090 上生成（2026-11-18）

- **forest_lookup_test**（sm_89 构建，4090）：**10 of 10 groups run and written**——
  10 组合成密钥的查找证明，各组文件 lookup_<i>.bin + .bin.values + lookup_groups.txt
  （0.3–17.6 MB/组，共 ~333 MB，在 l2alt/forest-groups/）；
- **forest_lookup_check.f2**（CPU checker，psc_rows.sh 构建）：**10 of 10 groups passed**——
  这批文件就是批次 C RTL 的对拍金标准（checker 的读取逻辑 = 语义规范，
  verifier/src/vf_lookup_argument.h + forest 表的树结构）；
- 测试的十组覆盖：小/大 slots、多 call、全 padding、PACKED 分类（sm_89 补丁改的那类）、
  恶意 prover 三式（key/multiplicity/crossed——checker 必须拒）；
- **RTL 设计的已知边界**：组内含 FS 哈希链（blocks/chain/chain.h）与折叠树——RTL 需要分
  层实现（树节点哈希批处理 + 直方图 + 折叠轮次），与批次 A 的 th_chain/merkle_builder
  同构可复用。

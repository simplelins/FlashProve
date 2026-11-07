# 07 · FlashProve vs DeepProve：精确对比（逐条可查证版 v2）

> **证据级别**：`[FP-doc]` = FlashProve 仓库文档（给出文件§节）；`[FP-code]` = 源码（文件:行）；
> `[DP-paper Lnnn]` = deepprove_text.txt 行号；`[笔记X]` = 你的 zkml_bootcamp 笔记；
> `[推导]` = 由已核实数据计算，给出算式。
> **未读区声明**：FORMAT.md 正文、paper.pdf、CUDA kernel 体、lean/*.lean、DP 论文 §4.3 各算子
> 协议细节与附录 B——以下凡涉及其内容均为转述，引用前请核对。
> **表格数据注意**：DP 论文 Table 1/2 在 PDF 转文本后列序错乱，我只引用**正文散文句明确
> 陈述**的数字（每条注明 L 行号），不引用我无法确定列名的单元格。

---

## 1. 规模对比：先把双方的硬数字钉死

### 1.1 FlashProve 证明的模型有多大——由 model.md 形状参数推出 `[FP-doc: model.md §2]` + `[推导]`

形状：d=5120，n_h=40，n_g=8，dh=128 ⇒ dq=5120、dkv=1024；f=16384（稠密 FFN）；fe=8192
（专家宽）；NE=128（路由专家）；V=202048；L=48 层（NE>0 ⇒ 奇数层 MoE、偶数层稠密，
即 24+24）。无 bias，norm 增益折进矩阵（model.md §3）。

| 组件 | 算式 | 参数量 |
|---|---|---|
| 注意力（每层） | Wq 5120×5120 + Wk 5120×1024 + Wv 同 + Wo 5120×5120 | 62,914,560 |
| 稠密 FFN（每稠密层） | 3 × (5120×16384) | 251,658,240 |
| 稠密层合计 | 62,914,560 + 251,658,240 | **314,572,800** |
| 共享专家 | 2×(5120×8192) + 8192×5120 | 125,829,120 |
| 路由器 Wr | 5120×128 | 655,360 |
| 单个路由专家 | 同共享专家形状 | 125,829,120 |
| MoE 层激活合计（1 专家） | 62,914,560+125,829,120+655,360+125,829,120 | **315,228,160** |
| MoE 层全量（128 专家） | 315,228,160 + 127×125,829,120 | 16,295,526,400 |
| Emb / Wh | 各 202,048×5120 | 各 1,034,485,760 |

**总参数** = 24×314,572,800 + 24×16,295,526,400 + 2×1,034,485,760 = **400,707,352,320 ≈ 400.7B**
——与"Llama 4 Maverick 400B"的公开规格一致 `[推导]`。
**每 token 激活** = 24×314,572,800 + 24×315,228,160 + 2×1,034,485,760 = **17,184,194,560 ≈ 17.2B**
——与公开的"~17B 激活"一致 `[推导]`。（Emb 实际每 pass 只查 T=1024 行；17.2B 是把 Emb/Wh
全额计入的口径。）

### 1.2 DeepProve 的评测规模与它自己的外推 `[DP-paper]`

- 评测模型：GPT-2 **124M**、Gemma 3 **270M**，12-bit 量化（L836-837）。
- 机器：主评机 AMD EPYC 9254 **24 核 2.9GHz / 504GB RAM**；副机 Ryzen 9 7950X3D **16 核
  4.2GHz / 128GB**（L814-817）。
- **内存随规模线性**："memory consumption … scales linearly with both the sequence length
  and … the model size … proportional to the circuit size being proven"（L920-924）。
- **DP 自己的外推**（这是全对比最硬的一条）："proving models with more than 3 billion
  parameters, such as GPT-J, would likely require over a terabyte of RAM"（L938-940）；
  论文称内存"the main bottleneck of our prover"（L938）。
- 最大实测内存：Gemma 3 seq512：BaseFold **96GB**、HKZG **147GB**（L932-933）；HKZG 在
  副机上 Gemma3-512 **OOM**（Table 2，L904 "OOM"）。

### 1.3 摊到每参数的内存 `[推导]`

- FP：承诺期 host RAM 峰值 299.6GB（maverick 实测 309.6GB†）/ **400.7B 参数 ≈ 0.75 B/参数**；
  服务期 269.7GB（公开权重 4-bit，232GB 文件在盘）`[FP-doc: perf.md "Machine"]`。
- DP：96GB / 270M ≈ **356 B/参数**（BaseFold 最大实例）`[DP-paper L932-933 + 推导]`。
- 两者相差约 **475×**。原因不是工程粗糙，而是架构性：DP 把权重/见证表示为域元素多项式
  常驻内存；FP 的权重保持 GGUF 量化块在盘上，承诺表**每批两趟流式重算**（见 §3.1）。

---

## 2. 架构差异：精确到协议对象

### 2.1 DeepProve 的证明结构 `[DP-paper L420-436, L487-513]`

1. **Preprocessing（每模型一次）**：Parsing（safetensors/GGUF/ONNX → 算子 DAG）→ 量化
   （对称仿射、校准集、outlier clamp）→ **模型承诺**：每个权重张量 W_i 表示为 multilinear
   函数 f_{i,j}，经 PCS 承诺；PCS 无同态则 batch commit 一次，有同态则逐多项式承诺
   （L487-499）。权重承诺 + scales 交给 prover 和 verifier（L456-458）。
2. **Proving（每输入一次）**：量化推理记录 trace → **见证承诺**（只承诺"explicitly need to
   be committed and cannot be virtualized"的值，即 LogUp-GKR 的查表 witness 与表，
   L491-493）→ 算子证明**自输出层向输入层逐层**（GKR 式，L495-499）：顶层声称来自 FS；
   每个算子协议产出 (1) 本算子正确性证明 (2) 对所用模型参数的声称 (3) 对本层 witness 的
   声称（L509-513）——声称沿层向下传递，最终由权重承诺的开式结算。
3. **不承诺 trace**："our approach does not commit to intermediate values … beyond model
   parameters and the witness values needed for lookup arguments"（L433-435）。
4. **PCS 两个实例**：BaseFold（Goldilocks 域，Ceno 库，"plausible post-quantum secure"）
   与 HyperKZG（BN254，"achieves shorter proofs"）（L824-831）。**你的代码基线 =
   BN254/HyperKZG** `[笔记D: Fr=ark_bn254::Fr；笔记J: BN254/HyperKZG]`。
5. HKZG 的工程优势：对 witness 多项式的承诺计算更高效（trace 是小位宽标量）+ 同态性
   ⇒ 打开前把所有待开多项式随机合并成一个（L929-947）。

### 2.2 FlashProve 的证明结构 `[FP-code: blocks/iop/lin.h, foldeq.h；FP-doc: 协议§5-6]`

**权重承诺对象**：committed table（`Index`）= 2^v 行、每行一个 RS 码字、列哈希进 Merkle
树、"outlives every proof and is no proof's oracle message"（foldeq.h L9-10）。行 = 权重数字位
块 + 随机尾巴（query bound）+ OOD pad（每答案 3 个 F64 元素 = 1 个 E 元素，foldeq.h
L489-491）。承诺方式 = **Ligero/Brakedown 式表承诺**（foldeq.h L27-38 引用 ePrint
2022/1608 §4.1/5.1 与 ePrint 2021/1043 §4.1）+ CFW proximity test（ePrint 2026/391）。

**LIN 协议（整批对表的声称）三部曲**（lin.h L6-22，逐字）：
- M 有 `matrix_rows` 行 × 2^k_col 列（k_col = k_lo + v）；请求 c 的声称
  `<g_c(x) eq(ψ_c,·), M> + (mask entries) = τ_c`。
- **First（每请求，跑在请求第一条链）**：prover 发 **W_c = g_cᵀ M**（每列一项）；
  (Eval)：W_c(ψ_c) + masks = τ_c。
- **Shared（每批一次，跑在共享链）**：验证者抽共享点 ψ*=(ψ_lo, γ)（k_lo+v 个 E 元素）；
  FOLDEQ 在 γ 处把表的行折成 G_u（编码线性 ⇒ 折叠码字），**开列一次**；发
  **Omega[y] = eq(ψ_lo,·) 与 u 中属于 y 的 2^k_lo 项的内积**（即 Omega = M·eq(ψ_lo,·)，
  每 M 行一项）；(Fold)：Omega(ζ) = ⟨eq(ψ_lo,·)(x)eq(ζ,·), u⟩。
- **Second（每请求，第二条链，输入 = 两条 seal）**：(Dot)：⟨g_c, Omega⟩ = W_c(ψ*)。
- **精确 soundness**（lin.h L408-410 逐字）：ψ* 的误差 **N·(k_lo+v)/|E|**（N=批内请求数，
  "both sides of (Dot) are multilinear in ψ* and W_c was fixed before"）；ζ 的误差 **k_row/|E|**。
- **批间绑定**：各请求 first chain 的 seal 为盐化 binding tree 的叶（盐 40 字节、深 ≤48），
  根进共享链首查询替代随机字节；未占叶 = 均匀摘要——"a path shows neither how many
  requests share the batch nor anything of their seals"（lin.h L662-664, L787-790）。
  学术出处（代码注释注明）：USENIX Security 2022 "Polynomial Commitment with a
  One-to-Many Prover"（共享挑战）+ ePrint 2023/492（批签名的批内隐私）。
- **(Eval)/(Dot) 行的形式**引自 Greyhound（ePrint 2024/1293 §1.2 式(2)、§3.1 图1）——只取
  形式，Omega 在此被提交（lin.h L26-29）。

**磨计数在库内强制**：`lin_begin()` → `index.begin(S.fold.columns)`；"An abandoned proof has
spent its columns all the same. So whoever keeps the count … must write it, where every later
reading finds it, before this call returns … durable … before fold() … because the columns are
drawn after that call"（foldeq.h L549-556）。**OOD 绑定的顺序规则**："The answers must come
before every gamma: a prover that knows gamma first fits them to any close table. So every chain
that draws a gamma must have the record in its first query"（foldeq.h L228-230）。

**规模相关的具体数字**：一个声称可含数千个 Tensor——"the committer's, in a key file:
**11,401** at a model of 400 billion weights; a request's: some hundreds"（lin.h L273-275）；
prover 在 Tensor 数 ≥1024 时合并为一个 2^k_row 稠密张量（lin_written_out_from，L280）。

**proximity test 数量**：LIN 一次批最多 **4** 个共享测（test_u / test_omega / test_own /
test_own_omega，lin.h L85-89）+ 每请求至多 2 个；Omega 被 **1+N** 次测试打开，其随机尾巴
必须覆盖全部（lin.h L414-415, L636-639）——隐藏预算的代码级核算。

---

## 3. 为什么 FlashProve 能扛 400B：六个机制，每个配代码证据

### 3.1 权重不进承诺热路径：两趟流式，表不驻留
`[FP-code: foldeq.h L530-533]`：IndexHolder "need not store the codewords: **fold() is one pass
over the rows, and open() may be a second that computes the drawn columns again**"。
`[FP-doc: architecture.md "Why step 4 needs two passes"]`：第一趟在批内所有 first chain 结束后
的折叠点折行 → 提交折叠行 → 采样列位置 → 第二趟重算所抽列。消息顺序定死在
`blocks/iop/lin.h` 与 `foldeq.h` 顶部。
**对比 DP**：权重表示为域元素多项式常驻（§1.3 的 356 B/参数）。

### 3.2 批内存峰值 = 折叠行，测后即释
`[FP-code: lin.h L552-560]`：`release_oracles(P, done); // the folded row is the largest object
that a batch creates`。折叠行长度 = 一个码字长（ell + r，foldeq.h L596-600），与表总尺寸
无关地被 2^v 行数摊薄。

### 3.3 段折叠：trace 不驻留、不落盘
`[FP-doc: 协议§6.3]`："The prover folds each segment's commitments into one short commitment
and carries it into the next segment, so it need not keep the whole trace."
**对比 DP**：流式路径用内存 pin + 段证明后释放达成同一目标 `[笔记J]`，代价：种子链强制
段间串行（J 文档 L-3）、查表证明每段一次固定开销（J 文档 L-4）。你的实测：llama-2-7b
512 prompt **125 段 14.15h，段固定开销主导** `[笔记M]`。

### 3.4 MoE 激活稀疏 + 每批只算激活路径
每 MoE 层每 token 激活 1 个路由专家（argmax, 并列取最小索引）+ 1 个共享专家（model.md
§7）⇒ 每 token 计算量 ≈ 17.2B 参数等效（§1.1）。DP 评测全部是 dense 模型。

### 3.5 LIN 批摊销：声音性损失有精确公式
共享点误差 N(k_lo+v)/|E|（lin.h L408-410）：|E|≈2^192，N≤64、k_lo+v≈几十 ⇒ 误差量级
~64×40/2^192 ≈ 2^-185——**批摊销几乎不花声音性**。开列次数 O(1)/批。DP 无对应结构
（无表承诺），其"批"只在算子内部（batched variants，L424-425）。

### 3.6 承诺层零 MSM、零配对、零可信设置
Ligero/Brakedown 式表承诺 + BLAKE2b + Goldilocks（E=F[X]/(X³−2)）。DP 的 HKZG 需 BN254
MSM 与配对验证；BaseFold 版虽哈希化，但承诺对象是 witness 多项式（trace 大）。

---

## 4. 性能：双方数字并排（条件全部标明）

### 4.1 FlashProve `[FP-doc: perf.md；条件 = 1×H100 80GB、24/96 CPU、公开 4-bit 权重、1024-token prompt、n=3]`

| 批大小 | tok/s | s/请求 | 批等待 |
|---|---|---|---|
| 1 | 17.41±0.15 | 58.796±0.50 | – |
| 8 | 76.34±0.37 | 13.413±0.065 | – |
| 24 | 111.23±0.92 | 9.206±0.077 | 220.7–225.9 s |
| 64 | 123.31±0.42 | – | 533.3–537.9 s |

批摊销倍数 `[推导]`：8/1=4.39×、24/1=6.39×、64/1=7.08×。
其余：证明 18.78MB 均值；客户端一次性下载 6.24MB；提供商每承诺 2.15GB（-M 1）；承诺
2,307.45–2,343.76s；含启动 103.60±0.84 tok/s；含承诺摊入前 1000 请求 88.81±0.46（不达标）；
整回复 clipped-gap 全检 108.67±2.8 tok/s（只数回复 token 39.1±1.0）。
成本：**93.0×**（92.2–94.1）vLLM FP8 8×H100 最高负载 prefill / GPU；**71.4×**（65.2–76.4）对
24 请求 prefill；**20.1×**（19.7–20.5）对 512 流解码。
验证：cp_verify ~21s（单线程）/3.53GB（24 线程）；Lean 验证器 1,393–1,440s/≤14.13GB†。
中间件检查：批 24 = 94.0s（单证 22.6s）；伴随服务 ~89s，吞吐损失不可见（109.64 vs 110.11）。
64/批：公开权重 GPU 80,629/81,559 MiB、960/960 证明通过；**合成权重 8 次尝试全部 CUDA
调用失败**（原因未知）。
磨寿命 `[推导]`：688,127 批/leaf × 64 请求/批 = **44,040,128 请求/leaf 上限**；承诺 2,343.76s
摊入 = **53µs/请求**。
准确率：整数模型 top-1 与 16-bit 模型差 **6.81%†** 位置（Python 实现）⇒ exact match 对
普通引擎文本不可用（96 条存证回复 0 条全对）⇒ 服务用 clipped gap。

### 4.2 DeepProve（只引散文句核实的数字）`[DP-paper]`

- 主机峰值吞吐："127 TPM for GPT-2 and 64 TPM for Gemma 3, both at sequence length 512
  using HyperKZG"（L953-955）。
- 副机："174 TPM and 146 TPM for GPT-2 at sequence lengths 512 using BaseFold and HyperKZG"；
  全实验最佳 175 TPM（GPT-2 seq256 BaseFold 副机）（L855-863, L956-958）。
- 吞吐随序列长增长（摊销，L952-955）；prover 时间随模型大小线性（L917-918）。
- 基线对比：zkGPT GPT-2 = **2.75 TPM**（16 核/200GB/32 线程）、zkTorch GPT-J = **0.09 TPM**
  （32 核/4TB）（Table 3, L963-968）⇒ DP 快 20–60×（摘要 L40）。
- 验证 1.2–3.2s（GPT-2）/≤3.5s（Gemma3）；证明 9–43MiB；HKZG 证明恒更短（L911-916）。
- 瓶颈分解："PCS constitutes the main bottleneck of the prover; however, it does not fully
  dominate"；"more than 50% of the prover cost comes from activation functions, Softmax, and
  requantization, with the latter … accounting for 27% of total prover time"（L892-907）。
- 内存是主瓶颈（L938）；3B+ 参数外推 >1TB RAM（L938-940）。
- 准确率：GPT-2 12-bit perplexity 49.4863 vs 浮点基线 49.2198（+0.54%）、cosine 0.9966；
  Gemma3 12-bit ppl 454.72 vs 基线 515.46（表 4）；8→12-bit 只加 0.8% prover 时间（L1004-1005）。

### 4.3 直接对比的诚实结论

- **原始吞吐不可直接比**：硬件（H100 vs EPYC CPU）、模型（400B/17.2B 激活 vs 124M）、
  序列长度、证明语义（FP=承诺模型+ZK；DP=公开模型完整性）全部不同。
- **可Defense的外推对比只有一条**：内存-规模曲线。DP 自己声明线性于电路规模并在 3B 处
  外推 >1TB；FP 在 400.7B 上实测 ≤309.6GB host RAM。差距的架构根源见 §3。
- **验证端可比**：DP 1.2–3.2s（GPT-2，配对）；FP 21s（400B，纯哈希）。FP 的验证对象大
  3 个数量级而时间只多 ~10×。

---

## 5. 对 DeepProve 的借鉴（每条配可执行依据）

**A. FPGA 路线切 BaseFold/Goldilocks**：论文已有该版本（L824-831）；FP 的算子画像（64-bit
延迟约减乘法 `[FP-code: pREADME field/ "arithmetic with delayed reduction"]`、BLAKE2b、
Merkle、fold/tensor）即哈希类 zkML 的 FPGA 算子清单。HKZG 的 MSM/配对在 FPGA 上是
痛点（随机访问 bucket 内存）。

**B. 闭源场景补"承诺三件套"**（FP 全部有库级实现可抄）：
- 隐藏：RS 随机尾巴（query bound）+ 每答案独立 pad；
- 复用：`IndexHolder::begin()` 计数先于打开且必须持久化（foldeq.h L549-556）；
- 绑定：record-before-γ 顺序规则（foldeq.h L228-230）+ 表名 = root+配置摘要+六个形状数
  （index_name，foldeq.h L303-309）。

**C. 表/查表证明全局化 = LIN 的三个现成件**：一次折叠（FOLDEQ）+ 声称批量（BATT/
Member）+ 批内隐私树（binding tree，出处 USENIX 2022 + ePrint 2023/492）。直接对应你
J 文档 L-4 的候选优化；预计缓解 7B 模型的段开销主导 `[笔记M]`。

**D. 误差账目工具**：FP 的 plan/`require_table(priced_table)`/target 机制（foldeq.h L197-208、
lin.h L489-492）保证"每轮误差从配置+验证器代码算，不从文件读"。DP 可仿制；对 FPGA
位宽规划直接有用。

**E. FP 应学 DP 的**：分布式证明（水平切块 + 块输入/输出承诺绑定，且"requires a **single
round** of interaction between workers and coordinator"——L806-808，比多数分布式 prover
少一轮交互）；量化精度工程（12-bit 0.54% ppl 偏差 + 0.8% prover 开销）；proof-of-non-
hallucination（应用层，AUROC 68.69% vs 浮点 68.29%，量化后略升，L982-994）。

---

## 6. 一页结论

1. **路线本质**：DP = "GKR 式逐层合成 + 权重/查表见证的 PCS 承诺（不隐藏）"；FP =
   "Ligero/Brakedown 式表承诺 + OOD 绑定 + LIN 批共享 + 段折叠 trace + 全哈希 + ZK"。
2. **400B 的可行性来自**：权重两趟流式（不驻留）、批峰值=折叠行即释、段折叠、MoE 稀疏
   （17.2B 激活）、LIN 摊销（误差 N(k_lo+v)/2^192）、零 MSM。DP 的线性内存 + 3B/>1TB
   外推是其规模墙（其论文自认）。
3. **DP 最值得马上做的三件事**：FPGA 基线换 Goldilocks/BaseFold；表证明全局化（LIN 三件
   套）；若做闭源模型，按 foldeq.h/lin.h 的库级机制补三件套。
4. **两系统共同的主战场是 sumcheck**（你笔记 D：段 C 占 84%；FP 块层 FOLD/PSC/LIN 为
   热路径）——差异全部在 PCS 与承诺语义层。

---

*版本 v2（精确化重写）· 2026-11-05。所有 DP 数字均给出 L 行号；所有 FP 机制均给出文件:行；
两处 `[推导]`（参数量核算、磨寿命）给出完整算式。未读区域见开头声明。*

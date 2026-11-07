# 11 · CPU+ASIC 十维度研究工作区（FlashProve 全尺寸证明器）

> 目标：Llama 4 Maverick 全尺寸证明在 **CPU+FPGA**（当前）→ **CPU+ASIC**（最终）跑通。
> 本文档是十个维度的工作台账：每个维度 = 已有数据 + 本轮产出 + 下一步。
> 数据来源：官方 performance.md（H100）、sm89-port 移植实测（4090）、
> `cp_verify -plan accounting`（全尺寸 Plan，见 §5）。

---

## 维度 1：工作负载特征化（M0 地基）

**已有**：端到端锚点（111 tok/s@批24、93× vLLM、commit 39 min、verify 21 s）。
**本轮新增**：
- 全尺寸 Plan 实测（§5）：**67,383 轮 / 62,421 轮带验证者消息**；
- nsys/ncu 在本机可用（cuda-13.1 bin）→ **out24 构建后对小 kit 跑内核级 profile**
  （正在进行，结果回填本节）；
- 分析锚点：模型前向仅 388 GOP/token（4090 int8 ≈1 ms）⇒ **93× 开销全在证明机制**。

**待回填**：内核级耗时表（哈希/sumcheck/查表/GEMM/内存 五类占比）→ 决定 ASIC 面积分配。

**M0 实测记录（2026-11-07）**：
- `cp_verify -plan accounting target_full_f2 128`：**67,383 轮 / 62,421 带验证者消息**；
  PoW 三档 20/28/32 bit；68 轮距目标 <0.01 bit（25 smallness + 43 closeness）；
- nsys 对 cp_prove 的 CUDA 注入失败（test build 亦然，两进程启动模式 defeated）；
  替代路径：①`ncu` 逐内核定点测（开销大但可控）；②CUPTI callback 自写采样器；
  ③在关键内核前后加 `cudaEvent` 计时（改 test build 源码，一次性插桩）——
  ③最直接，建议与 M1 的 RTL testbench 共用同一组输入向量。

## 维度 2：算子→硬件映射决策矩阵

| 内核族 | 算术 | 映射 | 理由（实测依据） |
|---|---|---|---|
| BLAKE2b（树 2^32 叶/FS 链/PoW） | 12 轮流式压缩 | **ASIC/FPGA 引擎** | GPU 仅 ~15 GB/s；commit 39 min 的主体 |
| Goldilocks 域乘 + E 三字 | 2^64≡2^32−1 特殊约减 | **域 ALU 流水线** | sumcheck 底座；免 Montgomery |
| PSC masked sumcheck | eq 张量×trace 折叠 | **sumcheck 引擎** | 轮间串行、内存流式 |
| 查表森林（PACKED 131KB/RANGE/LIMB） | 直方图+表查 | **片上 SRAM** | shared 墙（59/130/214/128/131 KB）全部消失 |
| int8 GEMM（gram m192×k≤4096、专家 FFN） | tensor core 已优 | **留 GPU/最小档** | 实测：cublasGemmEx b0 数值 0 错；ASIC 无增量 |
| RS 编码 / Merkle 构建 | NTT 类+哈希 | 与哈希引擎合流 | commit 主体 |

## 维度 3：微架构（五引擎）

1. **哈希引擎**：12 级流水 BLAKE2b ×N 实例；输入 128B 块；喂树/链/PoW；
2. **域 ALU**：Goldilocks 乘（约减 ~5 ops）+ E 扩域（K3 三字 24B）+ eq/折叠单元；
3. **查表引擎**：131 KB packed 表驻 SRAM/URAM + 直方图单元（count_keys16 语义）；
4. **GEMM 阵列**：int8 systolic（规模待维度 1 数据定，可能最小档）；
5. **Coin 引擎**：ChaCha20 派生（fresh bytes/批；second_writing 对照思想硬件化）。

## 维度 4：存储层次与数据流（定量）

| 数据 | 全尺寸大小 | 位置 | 流量账 |
|---|---|---|---|
| 权重（4-bit） | 232 GB | 主机内存，每批流式 2 遍 | 464 GB/批 ÷ Gen5 128 GB/s ≈ **3.6 s/批**（可忽略） |
| folded row | ~9.7 GB | 卡上 HBM | 批内最大对象；轮间依赖 |
| trace slab | 小 kit 1.47 GB；全尺寸数十 GB | 卡上 HBM（36-48 GB/栈） | 禁止 PCIe 往返（轮间挑战依赖） |
| kept 树层 | 1.07 GB/表副本 | 卡上 HBM | hc-own-node 重算比对对象 |
| packed 查表 | 131 KB×组 | 片上 SRAM | 常驻，零传输 |

**红线**：任何中间态回主机的方案被轮间依赖打死。

## 维度 5：CPU–ASIC 接口与协议（本轮实测定案）

- **全尺寸 Plan = 67,383 轮，62,421 轮带验证者消息**（`cp_verify -plan accounting
  target_full_f2 128` 实测；PoW 20/28/32 bit 三档；68 轮距目标 <0.01 bit）；
- **往返预算**：62,421 × PCIe RTT(~10 µs) ≈ 0.62 s/请求（可接受）；驱动开销 ~100 µs
  则 6.2 s/请求（吃掉一半）⇒ **FS 链必须上卡**（哈希引擎+链状态在卡上 HBM），
  CPU 只做批首/批尾交互；
- 接口规范直接用 blocks 的 **typed rounds**（rounds.h：每轮类型/尺寸/错误/PoW 已
  形式化）——RTL 接口照抄。

## 维度 6：正确性方法论

- 金标准三层：`cp_verify` YES → Lean 可执行验证器 → 差分测试（ASIC 证明 vs 发布程序
  证明，同 kit 同请求，中间值逐块对拍）；
- **现成块级 testbench**（已实测可用）：psc_layer 17 case、token_sumcheck 184、
  attention 137、forest_lookup 10 组（**含 PACKED 组**——本轮为覆盖缺口补的测试）、
  tail_gam、hash_vectors 57 行 KAT（`zk-bootcamp/probes/`）；
- 纪律：每个 RTL 块先过 CPU 参考（hf_mask_ref/second_writing 思想）再集成；
  **同步/屏障类 bug 只有逐值对拍能抓**（PackedSrc 屏障丢失的教训，09 报告附 8）。

## 维度 7：安全边界移植

- seed/秘密目录单点持有（ASIC 内部，不可导出/恢复）；计数器**先于开列且持久化**；
- ChaCha fresh bytes/批；**bring-up 用 `-public-weights`**（maverick 路线，
  examples/maverick/run.sh = 端到端金标准）；秘密模式在差分全绿后启用；
- 时间侧信道：官方声明可见（what-is-not-hidden），硬件不新增承诺。

## 维度 8：物理实现估算

| 项 | 估算 | 依据 |
|---|---|---|
| BLAKE2b 引擎 | 12 级流水 @1 GHz，~几 mm² | 200+ GB/s 目标 vs commit 需 ~120 GB/s |
| 域 ALU | 64-bit 乘+特殊约减 ×N 路 | Goldilocks 约减 ~5 ops |
| SRAM | 数 MB（最大单内核 214 KB × 并发）+ 查表数十 MB | 移植墙清单 |
| HBM | ≥32 GB/卡 | folded 9.7 GB + slab + kept 层 |
| 工艺/功耗 | 7/5 nm；哈希+SRAM 主导，低于 GPU 张量阵列一个量级 | — |

## 维度 9：风险登记

| 风险 | 缓解 |
|---|---|
| 93× 分解未知（GEMM 占比若高，ASIC 收益缩水） | **维度 1 profile 先行** |
| FS 链串行 | 链上引擎；轮次已实测（67,383） |
| 参数"无余量"（68 轮 <0.01 bit） | 任何数值偏差=作废 → 差分全覆盖 |
| 秘密/计数器纪律硬件化 | public-weights 先行 |
| 技术报告不公开（HW-763） | Lean 规范 + cp_verify 行为为金标准 |
| batch-64 显存墙（80,629/81,559 MiB） | ASIC HBM 反而宽松；过渡期减 batch |

## 维度 10：里程碑

| 里程碑 | 门槛 | 状态 |
|---|---|---|
| M0 profile | 内核占比表 | **进行中（out24 构建+nsys）** |
| M1a FPGA | BLAKE2b 核 Verilator KAT 57 行全过 | 金标准已备（probes/） |
| M1b FPGA | 树构建器上板，commit 哈希 ≥100 GB/s | — |
| M2 FPGA | 域 ALU+sumcheck，psc_layer 17 case bit-exact | — |
| M3 ASIC spec | 微架构 spec+面积功耗 → 流片决策 | — |
| M4 bring-up | maverick public-weights 全流程 → cp_verify YES | — |
| M5 | 秘密模式+批处理+对标 111 tok/s | — |

---

*台账规则：每维度的新数据直接回填本节；M0 的 profile 表是下一个大回填。*

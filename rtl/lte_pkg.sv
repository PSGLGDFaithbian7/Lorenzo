//==============================================================================
// lte_pkg.sv
//------------------------------------------------------------------------------
// Lorenzo Task Engine V0.3 —— 乙方(B, 控制面/配置) 共享定义包
//
// 本包集中定义：
//   1. 固定结构常量 (NUM_SA / PE_NUMBER / GROUP_SIZE ... )
//   2. 各循环层级的最大规模 (HEAD_NUM_MAX / context block / dim group ...)
//      —— 用于推导计数器位宽
//   3. 错误码枚举 (ISA §9)
//   4. task_ctx_t / deq_token_meta_t / drain_token_meta_t 结构体
//
// 设计约束(对应分工计划/微架构 §2.2)：
//   - 所有需要 取模/除法 的循环常量 (dim/32, ceil(ctx/32) ...) 一律由 Host 片外
//     预先算好, 通过 TDT 配置进来; 片上 RTL 不在热路径里做除法/求余。
//   - 本包仅含纯定义, 不含任何逻辑。
//==============================================================================
package lte_pkg;

  //----------------------------------------------------------------------------
  // 1. 固定结构常量 (RTL Design Spec §1.1)
  //----------------------------------------------------------------------------
  localparam int NUM_SA         = 4;    // SA 阵列数 (4 x 1x32 output-stationary)
  localparam int PE_PER_SA      = 32;   // 每个 SA 的 PE 数
  localparam int PE_NUMBER      = 128;  // 总 PE lane 数 = NUM_SA * PE_PER_SA
  localparam int GROUP_SIZE     = 32;   // 逻辑 group 固定 32
  localparam int HP_MAX         = 4;    // PV 最大并行 head 数 (head_dim=32 时)
  localparam int DRAIN_LANE_NUM = 32;   // 一个 context block / head tile 的 drain lane 数

  //----------------------------------------------------------------------------
  // 2. 循环规模上限 (与参考 u_loop_nest_control.sv 保持一致)
  //    这些只决定计数器位宽, 不参与运行期运算。
  //----------------------------------------------------------------------------
  localparam int GROUP_SIZE_MAX           = 32;   // 一组最大 32
  localparam int HEAD_NUM_MAX             = 48;   // 最多 48 个 head
  localparam int QK_CONTEXT_BLOCK_NUM_MAX = 563;  // ctx_len 支持 563*32 = 18016
  localparam int QK_DIM_GROUP_NUM_MAX     = 16;   // dim_per_head 支持 16*32 = 512
  localparam int PV_CONTEXT_GROUP_NUM_MAX = 563;  // ctx_len 支持 563*32 = 18016
  localparam int PARALLEL_MAX             = 4;    // PV 阶段最多 4 head 并行

  //----------------------------------------------------------------------------
  // 3. 由上限推导的计数器位宽 (与参考 .sv 的 localparam 完全对应)
  //----------------------------------------------------------------------------
  localparam int HEAD_W       = $clog2(HEAD_NUM_MAX);              // head_ctr 位宽
  localparam int HEAD_COUNT_W = $clog2(HEAD_NUM_MAX + 1);          // num_heads 计数位宽
  localparam int QK_CTX_W     = $clog2(QK_CONTEXT_BLOCK_NUM_MAX);  // context_ctr 位宽
  localparam int QK_GRP_W     = $clog2(QK_DIM_GROUP_NUM_MAX);
  localparam int PV_GRP_W     = $clog2(PV_CONTEXT_GROUP_NUM_MAX);
  localparam int GROUP_CTR_W  = (QK_GRP_W > PV_GRP_W) ? QK_GRP_W : PV_GRP_W; // 复用计数器
  localparam int INNER_W      = $clog2(GROUP_SIZE_MAX);            // inner_ctr 位宽
  localparam int DRAIN_W      = $clog2(DRAIN_LANE_NUM);            // drain_lane_ctr 位宽

  //----------------------------------------------------------------------------
  // 4. PE_VALID_LEN_DESC 打包格式 (ISA §6)
  //    per SA: {mask_mode[1b], valid_len[6b]}; 这里按 8-bit/ SA 对齐切片便于解码。
  //----------------------------------------------------------------------------
  localparam int PE_DESC_STRIDE = 8;  // pe_desc 每个 SA 占 8 bit
  localparam int VALID_LEN_W    = 6;  // valid_len 字段 6 bit (0..32)

  //----------------------------------------------------------------------------
  // 5. task_mode / desc_type 编码 (ISA §3)
  //----------------------------------------------------------------------------
  localparam logic [1:0] TASK_MODE_QK = 2'd0;
  localparam logic [1:0] TASK_MODE_PV = 2'd1;
  localparam logic [3:0] TDT_DESC_TYPE = 4'hD;//TASK + ID索引，选取正确的配置参数

  //----------------------------------------------------------------------------
  // 6. 错误码枚举 (ISA §9 / RTL Design Spec §5.19)
  //----------------------------------------------------------------------------
  localparam logic [7:0] ERR_NONE                    = 8'h00;
  localparam logic [7:0] ERR_ILLEGAL_TASK_DESC       = 8'h01;
  localparam logic [7:0] ERR_ILLEGAL_TASK_MODE       = 8'h02;
  localparam logic [7:0] ERR_TASK_ENGINE_BUSY        = 8'h03;
  localparam logic [7:0] ERR_ILLEGAL_GROUP_SIZE      = 8'h04;
  localparam logic [7:0] ERR_ILLEGAL_DIM             = 8'h05;
  localparam logic [7:0] ERR_ILLEGAL_CONTEXT         = 8'h06;
  localparam logic [7:0] ERR_ILLEGAL_PV_MAP          = 8'h07;
  localparam logic [7:0] ERR_ILLEGAL_STREAM_CONTRACT = 8'h08;
  localparam logic [7:0] ERR_TASK_BACKPRESSURE_DEBUG = 8'h09;

  //----------------------------------------------------------------------------
  // 7. 锁存后的 task 配置 (B2 lte_task_context 输出)
  //    标量字段集中放结构体; per-SA 的位向量在端口上单独走 (便于 generate)。
  //    存放从TDT所存下来的本task参数
  //----------------------------------------------------------------------------
  typedef struct packed {
    logic [1:0]  task_mode;               // 0=QK 1=PV
    logic [15:0] num_heads;               // 总 head 数
    logic [15:0] context_length;          // K 列数 / P,V context 长度
    logic [15:0] dim;                     // QK reduction dim
    logic [15:0] head_dim;                // PV 每 head dim 宽度
    logic [7:0]  group_size;              // 固定 32
    logic [7:0]  sa_per_head;             // PV: head_dim/32
    logic [7:0]  hp_parallel;             // PV: 128/head_dim
    logic [7:0]  flags;                   // TDT flags[7:0]
    logic [7:0]  q_buffer_policy;         // 0=line-valid 1=tile-ready
    logic [7:0]  output_mode;             // 0=A/softmax 1=O 2=SRAM_QP
    logic [7:0]  stream_contract;         // 0=canonical
    logic [7:0]  deq_prefill_hint;        // deq FIFO 预填深度建议
    logic [15:0] qk_dim_group_count;      // Host 预算: dim/32
    logic [15:0] qk_context_block_count;  // Host 预算: ceil(ctx/32)
    logic [31:0] qk_context_tail_mask;    // 最后一个 context block 的有效 lane
    logic [15:0] pv_context_group_count;  // Host 预算: ceil(ctx/32)
    logic [5:0]  pv_last_inner_count;     // 最后一个 PV group 的有效 inner 数 1..32
    logic [7:0]  active_sa_count;         // Full head tile active SA count.
    logic [7:0]  last_head_count;         // Last head tile head count from TDT reserved[25:18].
  } task_ctx_t;

  //----------------------------------------------------------------------------
  // 8. dequant token 的"控制面字段" (group_done 时由 B 锁入)
  //    bank id 字段属于甲方 datapath(双 bank 逻辑), 由 A 侧在出队时补齐, 不在此结构内。
  //    控制器给到计算阵列的信息
  //----------------------------------------------------------------------------
  typedef struct packed {
    logic                      mode;             // 0=QK 1=PV
    logic [HEAD_W-1:0]         head_tile_id;     // = head_ctr
    logic [QK_CTX_W-1:0]       context_block_id; // = context_ctr (QK)
    logic [GROUP_CTR_W-1:0]    group_id;         // = group_ctr
    logic                      last_group;       // 当前 block/tile 的最后一个逻辑 group
    logic                      last_ctx;         // QK: head tile 的最后一个 context block
    logic                      last_head;        // task 的最后一个 head tile
    logic [DRAIN_LANE_NUM-1:0] lane_valid_mask;  // QK tail mask / PV 全 1
  } deq_token_meta_t;

  //----------------------------------------------------------------------------
  // 9. drain token 的"控制面字段" (row_done / head_tile_done 时由 B 锁入)
  //    valid_len / use_output_lorenzo 走单独端口 (per-SA)。
  //----------------------------------------------------------------------------
  //给到排空单元的信息
  typedef struct packed {
    logic                      mode;             // 0=QK->softmax 1=PV->O
    logic [HEAD_W-1:0]         head_tile_id;
    logic [QK_CTX_W-1:0]       context_block_id;
    logic [DRAIN_LANE_NUM-1:0] lane_valid_mask;  // QK tail block mask / PV 全 1
    logic [7:0]                output_mode;
  } drain_token_meta_t;

endpackage : lte_pkg

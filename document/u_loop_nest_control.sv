module u_loop_next_ctrl #(
    //参数设置
    //一组最大为32
    parameter int GROUP_SIZE_MAX              = 32,
    //最多支持48个头
    parameter int HEAD_NUM_MAX                = 48,
    //context_length支持563*32 = 18016
    parameter int QK_CONTEXT_BLOCK_NUM_MAX    = 563,
    //Dim_Per_head支持 16*32 = 512
    parameter int QK_DIM_GROUP_NUM_MAX        = 16,
    //context_length支持563*32 = 18016
    parameter int PV_CONTEXT_GROUP_NUM_MAX    = 563,
    //最多支持32个lane连续排空
    parameter int DRAIN_LANE_NUM              = 32,
    //PV阶段最多支持4个头并行
    parameter int PARALLEL_MAX                = 4
) (
    //时钟复位
    input  logic clk,
    input  logic rst_n,
    //任务开始+KQ/PV模式选择
    //本代码定义竖着划分为group,横着划分为block
    input  logic task_start,
    input  logic [1:0] task_mode,   // 0: QK, 1: PV
    //head数
    input  logic [$clog2(HEAD_NUM_MAX+1)-1:0]             num_heads,
    //KQ阶段dim_group数目
    input  logic [$clog2(QK_DIM_GROUP_NUM_MAX+1)-1:0]     qk_dim_group_count,
    //KQ阶段context_block数目
    input  logic [$clog2(QK_CONTEXT_BLOCK_NUM_MAX+1)-1:0] qk_context_block_count,
    //KQ阶段最后一段context的长度
    input  logic [DRAIN_LANE_NUM-1:0]                     qk_context_tail_mask,
    input  logic [$clog2(PV_CONTEXT_GROUP_NUM_MAX+1)-1:0] pv_context_group_count,
    //PV阶段最后一个V输入组的数量
    input  logic [$clog2(GROUP_SIZE_MAX+1)-1:0]           pv_last_inner_count,
    //PV阶段head并行数
    input  logic [$clog2(PARALLEL_MAX+1)-1:0]             hp_parallel,

    // MAC side: only inner/group counters are allowed on this hot path.
    //mac完成一次乘加返回一次fire
    input  logic mac_fire,

    // Same-cycle accept for group_done_valid. The final MAC beat of a logical
    // group should only be issued when downstream can accept the group-done token.
    //一个group完全进入了dequant部分返回一次fire
    input  logic group_done_accept,

    // Drain side is independent from MAC scheduling.
    //一条lane输出一个就fire一次
    input  logic drain_fire,
    //对外状态展示
    //到第几个头
    output logic [$clog2(HEAD_NUM_MAX)-1:0]                head_ctr_o,
    //第几个context_block  
    output logic [$clog2(QK_CONTEXT_BLOCK_NUM_MAX)-1:0]    context_ctr_o,
    //PV:第几个context_group KQ:第几个dim_group
    output logic [$clog2(PV_CONTEXT_GROUP_NUM_MAX)-1:0]    group_ctr_o,
    //group内的第几个元素
    output logic [$clog2(GROUP_SIZE_MAX)-1:0]              inner_ctr_o,
    //输出到了第几个drain
    output logic [$clog2(DRAIN_LANE_NUM)-1:0]              drain_lane_ctr_o,

    //每个模块的最后一个，last_latch+fire=end_pulse
    //当前是不是本 group 的最后一个 inner。
    output logic is_inner_last,
    //当前是不是最后一个 group
    output logic is_group_last,
    //表示当前 QK 的 context_block 是不是最后一个
    output logic is_context_block_last,
    //当前是不是这个 head 的最后计算边界。
    //QK: 最后一个 context_block && 最后一个 dim_group
    //PV: 最后一个 context_group
    output logic is_head_tile_last,
    //当前是不是整个 task 的最后计算边界。
    //is_head_tile_last && is_last_head_tile
    output logic is_task_last,

    //最后一个
    output logic group_done_valid,
    // KQ:表示当前是不是最后一个 dim_group
    // PV:是否最后一个 context_group
    output logic group_done_last_group,
    //QK: 当前 context_block 是否是最后一个
    output logic group_done_last_ctx,
    //表示当前是不是最后一个 head_tile
    output logic group_done_last_head,
    /*QK:
    普通 context_block = 32'hFFFF_FFFF
    最后一个 partial context_block = qk_context_tail_mask
    PV:
    一般固定全 1*/
    output logic [DRAIN_LANE_NUM-1:0] group_done_lane_valid_mask
);

    localparam logic [1:0] TASK_MODE_QK = 2'd0;
    localparam logic [1:0] TASK_MODE_PV = 2'd1;

    localparam int HEAD_W        = $clog2(HEAD_NUM_MAX);
    localparam int HEAD_COUNT_W  = $clog2(HEAD_NUM_MAX+1);
    localparam int QK_CTX_W      = $clog2(QK_CONTEXT_BLOCK_NUM_MAX);
    localparam int QK_GRP_W      = $clog2(QK_DIM_GROUP_NUM_MAX);
    localparam int PV_GRP_W      = $clog2(PV_CONTEXT_GROUP_NUM_MAX);
    localparam int GROUP_CTR_W   = (QK_GRP_W > PV_GRP_W) ? QK_GRP_W : PV_GRP_W;
    localparam int INNER_W       = $clog2(GROUP_SIZE_MAX);
    localparam int DRAIN_W       = $clog2(DRAIN_LANE_NUM);
    //状态机状态
    typedef enum logic {
        TASK_IDLE = 1'b0,
        TASK_RUN  = 1'b1
    } state_e;
    //状态机变量
    state_e state_q, state_d;

    //本设计主体为状态机：task begin + task end 加上五个：inner,head,group,context_block,lane_drain计数器
    //上面的信号为配置信号，对外计数状态展示，每一层循环的单块终止信号，以及总终止信号

    //内部计数器
    //head计数器
    logic [HEAD_W-1:0]      head_ctr_q;
    //KQ用，context_block计数器
    logic [QK_CTX_W-1:0]    context_ctr_q;
    //dim_group或context_group用的计数器
    logic [GROUP_CTR_W-1:0] group_ctr_q;
    //group内计数器
    logic [INNER_W-1:0]     inner_ctr_q;
    //drain计数器
    logic [DRAIN_W-1:0]     drain_lane_ctr_q;

    logic context_last_q;

    logic head_last_q;

    logic [GROUP_CTR_W-1:0] group_max_minus1;

    logic [INNER_W-1:0]     pv_last_inner_minus1;

    logic [HEAD_COUNT_W-1:0] next_head_ctr_ext;

    logic [HEAD_COUNT_W-1:0] head_after_next_tile_ext;
    logic                   next_head_is_last;
    logic                   next_context_is_last;

    logic task_active;
    logic qk_mode;
    logic pv_mode;

    logic group_last_c;
    logic inner_last_c;
    logic mac_step_fire;
    logic inner_end;
    logic group_end;
    logic group_done_fire;
    logic qk_block_done_fire;
    logic pv_tile_done_fire;
    logic head_step_fire;
    logic task_done_fire;

    logic [DRAIN_LANE_NUM-1:0] current_lane_valid_mask;
    

    //TASK_RUN时置高active信号，代表正在工作中
    assign task_active = (state_q == TASK_RUN);
    //模式选择，根据task_mode置高qk_mode或者pv_mode
    assign qk_mode = (task_mode == TASK_MODE_QK);
    assign pv_mode = (task_mode == TASK_MODE_PV);
    

    //配置信号进来以后还要进一步配置：group,它在两个阶段意义不同
    // The generic group counter means different things by mode:
    // QK: dim_group. PV: context_group.
    //QK:为dim_group,PV为context_group
    always_comb begin
        if (qk_mode) begin
            group_max_minus1 = GROUP_CTR_W'(qk_dim_group_count - 1'b1);
        end else begin
            group_max_minus1 = GROUP_CTR_W'(pv_context_group_count - 1'b1);
        end
    end
   //接下来是各层循环的last条件
   //last为计数器到达指定值的电平，但是要结合运算级的反馈才可以发出end信号
    assign group_last_c = (group_ctr_q == group_max_minus1);
   

    //PV inner标准   
    always_comb begin
        pv_last_inner_minus1 = INNER_W'(pv_last_inner_count - 1'b1);
        //qkmode:inner last就是group_size的最后一个，group size一样大
        if (qk_mode) begin
            inner_last_c = (inner_ctr_q == INNER_W'(GROUP_SIZE_MAX-1));
        //但是在PV模式，context_group的最后一组，不一定够group size   
        end else if (group_last_c) begin
            inner_last_c = (inner_ctr_q == pv_last_inner_minus1);
            //其他情况和qk一样
        end else begin
            inner_last_c = (inner_ctr_q == INNER_W'(GROUP_SIZE_MAX-1));
        end
    end

    // For the final inner beat of a logical group, MAC step and group-done accept
    // must happen together. This prevents the lower-level counters from running
    // ahead of the group-done token path.
    //mac_fire允许的情况：task工作且mac_fire反馈而且不是group内最后一个->允许fire
    //若是最后一个，则反量化模组应该接受以后才可以fire
    assign mac_step_fire = task_active && mac_fire && (!inner_last_c || group_done_accept);

    // end = last && real fire. Lower-level counters only carry upward on end.
    //inner end ：inner计数到最后一个而且mac完成了这一步的计算，下一层循环靠end而非last启动，防止MAC没运算，循环本应停步，但是用last控制就会一直往下计数
    assign inner_end = mac_step_fire && inner_last_c;
    //一个group的完成
    assign group_end = inner_end;

    //qkmode而且最后一个context block 不是所有lane都在工作，遵循tail mask
    assign current_lane_valid_mask =
        (qk_mode && context_last_q) ? qk_context_tail_mask : {DRAIN_LANE_NUM{1'b1}};



   //总状态机
   //第一段：复位+转次态
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= TASK_IDLE;
        end else begin
            state_q <= state_d;
        end
    end
    //task_start信号->TASK_RUN
    //task_done_fire->TASK_IDLE
    always_comb begin
        state_d = state_q;
        unique case (state_q)
            TASK_IDLE: begin
                if (task_start) begin
                    state_d = TASK_RUN;
                end
            end
            TASK_RUN: begin
                if (task_done_fire) begin
                    state_d = TASK_IDLE;
                end
            end
            default: begin
                state_d = TASK_IDLE;
            end
        endcase
    end


    //摆脱了多层循环的状态机
    // MAC-side hot counters. These are the only counters advanced by mac_fire.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inner_ctr_q <= '0;
            group_ctr_q <= '0;
        end else if (task_start) begin
            inner_ctr_q <= '0;
            group_ctr_q <= '0;
        end else if (task_active) begin
         
            if (mac_step_fire) begin
                inner_ctr_q <= inner_last_c ? '0 : inner_ctr_q + 1'b1;
            end
            //一个group_end信号来了->不是最后一个+1是的话归零
            //这里就体现为什么不用last,如果后级没反应，last会一直为1，那group就会一直自增，这样可以把last由电平转为一拍的脉冲
            if (group_end) begin
                group_ctr_q <= group_last_c ? '0 : group_ctr_q + 1'b1;
            end
        end
    end

    // Boundary counters advance only when the group-done token is really accepted.
    //逐层嵌套，下一层的启动脉冲都要上一层的一次循环结束脉冲相与
    //一个group计算完成
    assign group_done_fire   = task_active && group_end && group_done_accept;
    //qk阶段下，一个context_block运算完成
    assign qk_block_done_fire = qk_mode && group_done_fire && group_done_last_group;
    //pv阶段下，一个context_group完成运算，等价于一个头完成
    assign pv_tile_done_fire  = pv_mode && group_done_fire && group_done_last_group;
    //一个head
    assign head_step_fire     = (qk_block_done_fire && group_done_last_ctx) || pv_tile_done_fire;
    //一个task
    assign task_done_fire     = head_step_fire && group_done_last_head;
    //conext_block计数器，QK专用
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            context_ctr_q <= '0;
        end else if (task_start) begin
            context_ctr_q <= '0;
        end else if (qk_block_done_fire) begin
            context_ctr_q <= context_last_q ? '0 : context_ctr_q + 1'b1;
        end
    end
    //head计数器，考虑PV阶段的多头并行
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_ctr_q <= '0;
        end else if (task_start) begin
            head_ctr_q <= '0;
        end else if (head_step_fire) begin
            head_ctr_q <= head_last_q ? '0 : next_head_ctr_ext[HEAD_W-1:0];
        end
    end
   
    always_comb begin
        //计算PV阶段到了第几个头
        next_head_ctr_ext = HEAD_COUNT_W'(head_ctr_q) + HEAD_COUNT_W'(hp_parallel);
        //下一个周期到了第几个头
        head_after_next_tile_ext = next_head_ctr_ext + HEAD_COUNT_W'(hp_parallel);
        //判定最后一个头批次
        next_head_is_last = (head_after_next_tile_ext >= HEAD_COUNT_W'(num_heads));
        //最后一个c_block批次
        next_context_is_last = (context_ctr_q + 1'b1 == QK_CTX_W'(qk_context_block_count - 1'b1));
    end



    // Registered predecode flags. Token packing consumes only these 1-bit flags.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            context_last_q <= 1'b0;
            head_last_q <= 1'b0;
        end else if (task_start) begin
            context_last_q <= (qk_context_block_count <= 1);
            head_last_q <= (hp_parallel >= num_heads);
        end else begin
            //最后一个c_block判定：一开始单block，直接为1.非单block按照累加值是否大于block总数目来
            if (qk_block_done_fire) begin
                context_last_q <= context_last_q ? (qk_context_block_count <= 1) : next_context_is_last;
            end
             //最后一个head判定：head并行>总head数，直接为1.否则按照累加值是否大于head总数目来
            if (head_step_fire) begin
                head_last_q <= head_last_q ? (hp_parallel >= num_heads) : next_head_is_last;
            end
        end
    end


//MAC输出计数器
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            drain_lane_ctr_q <= '0;
        end else if (task_start) begin
            drain_lane_ctr_q <= '0;
        end else if (task_active && drain_fire) begin
            drain_lane_ctr_q <= (drain_lane_ctr_q == DRAIN_W'(DRAIN_LANE_NUM-1)) ?
                                '0 : drain_lane_ctr_q + 1'b1;
        end
    end
   
   //对外输出接口
    assign group_done_valid = group_end;
    assign group_done_last_group = group_last_c;
    assign group_done_last_ctx = context_last_q;
    assign group_done_last_head = head_last_q;
    assign group_done_lane_valid_mask = current_lane_valid_mask;

    assign is_inner_last = inner_last_c;
    assign is_group_last = group_last_c;
    assign is_context_block_last = qk_mode && context_last_q;
    assign is_head_tile_last = qk_mode ? (context_last_q && group_last_c) : group_last_c;
    assign is_task_last = is_head_tile_last && head_last_q;

    assign head_ctr_o = head_ctr_q;
    assign context_ctr_o = context_ctr_q;
    assign group_ctr_o = group_ctr_q[$clog2(PV_CONTEXT_GROUP_NUM_MAX)-1:0];
    assign inner_ctr_o = inner_ctr_q;
    assign drain_lane_ctr_o = drain_lane_ctr_q;

endmodule

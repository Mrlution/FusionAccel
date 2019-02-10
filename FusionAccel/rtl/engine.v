//Instantiate 16CMACs for conv3x3, 16CMACs for conv1x1, maxpool and avepool in engine.
module engine(
	input 			clk,
	input 			rst,
	//Control signals from csb
	input 			conv_ready,
	input 			maxpool_ready,
	input 			avepool_ready,
	input [2:0] 	op_type,
	input [31:0] 	op_num,

	//Data path from dma -> fifos
	input [15:0] 	data_0,
	input [15:0] 	weight_0,
	input [15:0] 	data_1,
	input [15:0] 	weight_1,

	output 			p0_data_fifo_rd_en,
	output 			p0_weight_fifo_rd_en,
	output 			p1_data_fifo_rd_en,
	output 			p1_weight_fifo_rd_en,
	output 			conv_valid,
	output 			maxpool_valid,
	output 			avepool_valid,
	output [15:0]	result,
	output			p0_writes_en,
	output			p1_writes_en
	//Outputs write back
);

localparam CONV_BURST_LEN = 16;
localparam POOL_BURST_LEN = 1;
localparam CONV1 = 1;
localparam CONV3 = 2;
localparam CONVP = 3;
localparam MPOOL = 4;
localparam APOOL = 5;

reg  [7:0] conv_burst_cnt;
reg  [7:0] pool_burst_cnt;
reg  [CONV_BURST_LEN-1:0] conv_ready_0, conv_ready_1;
wire [CONV_BURST_LEN-1:0] rdy_acc_0, rdy_acc_1;
wire [CONV_BURST_LEN-1:0] conv_valid_0, conv_valid_1;

reg  [POOL_BURST_LEN-1:0] avepool_ready_0, maxpool_ready_0;
wire [POOL_BURST_LEN-1:0] rdy_avepool, rdy_maxpool;
wire [POOL_BURST_LEN-1:0] avepool_valid_0, maxpool_valid_0;

reg  [15:0] d0 [0:CONV_BURST_LEN-1];
reg  [15:0] w0 [0:CONV_BURST_LEN-1];
reg  [15:0] d1 [0:CONV_BURST_LEN-1];
reg  [15:0] w1 [0:CONV_BURST_LEN-1];
reg  [15:0] mp [0:POOL_BURST_LEN-1];
reg  [15:0] ap [0:POOL_BURST_LEN-1];

wire [15:0] conv_result_0 [0:CONV_BURST_LEN-1];
wire [15:0] conv_result_1 [0:CONV_BURST_LEN-1];

reg  [15:0] conv_count [0:CONV_BURST_LEN-1];
reg  [15:0] pool_count [0:POOL_BURST_LEN-1];
reg 		conv_finish;
reg 		conv_valid;
reg 		avepool_finish, maxpool_finish;
reg 		avepool_valid, maxpool_valid;

reg p0_data_fifo_rd_en, p1_data_fifo_rd_en, p0_weight_fifo_rd_en, p1_weight_fifo_rd_en;

always @(op_type or conv_valid_0 or conv_valid_1 or avepool_valid_0 or maxpool_valid_0) begin
	case(op_type)
		CONV1: begin
			if(conv_valid_1 == 16'hffff) conv_finish = 1;
			else conv_finish = 0;
		end
		CONV3: begin
			if(conv_valid_0 == 16'hffff) conv_finish = 1;
			else conv_finish = 0;
		end
		CONVP: begin
			if(conv_valid_0 == 16'hffff && conv_valid_1 == 16'hffff) conv_finish = 1;
			else conv_finish = 0;
		end
		MPOOL: begin
			if(maxpool_valid_0 == 1) maxpool_finish = 1;
			else maxpool_finish = 0;
		end
		APOOL: begin
			if(avepool_valid_0 == 1) avepool_finish = 1;
			else avepool_finish = 0;
		end
		default: begin conv_finish = 0; avepool_finish = 0; maxpool_finish = 0; end
	endcase
end

//Generate 16CMACs for CONV3x3
//Notes: CMACs start one by one, using the same data path. weight is enabled according to sel.
//Notes: Calculation of a cmac takes 20 cycles, if using pipeline fifo readout, 16 is the best.
genvar i;
generate 
	for (i = 0; i < CONV_BURST_LEN; i = i + 1) begin
		cmac cmac_0(.clk(clk), .rst(~conv_ready), .data(d0[i]), .weight(w0[i]), .result(conv_result_0[i]), .conv_ready(conv_ready_0[i]), .op_num(op_num), .rdy_acc(rdy_acc_0[i]), .conv_valid(conv_valid_0[i]));
	end 
endgenerate

//Generate 16CMACs for CONV1x1
genvar j;
generate 
	for (j = 0; j < CONV_BURST_LEN; j = j + 1) begin
		cmac cmac_1(.clk(clk), .rst(~conv_ready), .data(d1[j]), .weight(w1[j]), .result(conv_result_1[j]), .conv_ready(conv_ready_1[j]), .op_num(op_num), .rdy_acc(rdy_acc_1[j]), .conv_valid(conv_valid_1[j]));
	end 
endgenerate

genvar k;
generate
	for (k = 0; k < POOL_BURST_LEN; k = k + 1) begin
		sacc sacc_(.clk(clk), .rst(~avepool_ready), .data(ap[k]), .result(), .pool_ready(avepool_ready_0[k]), .op_num(op_num), .rdy(rdy_avepool[k]), .pool_valid(avepool_valid_0[k]));
	end
endgenerate

genvar l;
generate
	for (l = 0; l < POOL_BURST_LEN; l = l + 1) begin
		scmp scmp_(.clk(clk), .rst(~maxpool_ready), .data(mp[l]), .result(), .pool_ready(maxpool_ready_0[l]), .op_num(op_num), .rdy_cmp(rdy_maxpool[l]), .pool_valid(maxpool_valid_0[l]));
	end
endgenerate

//State Machine
localparam idle = 3'b000;
localparam conv_busy = 3'b001;
localparam conv_clear = 3'b010;
localparam maxpool_busy = 3'b011;
localparam maxpool_clear = 3'b100;
localparam avepool_busy = 3'b101;
localparam avepool_clear = 3'b110;
localparam finish = 3'b111;

reg [2:0] curr_state;
reg [2:0] next_state;

//    Current State, non-blocking
always @ (posedge clk or posedge rst)    begin
    if (rst)
        curr_state    <= idle;
    else
        curr_state    <= next_state;
end

//    Status Jump, blocking
always @ (*) begin
    next_state = idle;    //    Initialize
    case (curr_state)
        idle: begin
            if(conv_ready) next_state = conv_busy;
			else if(avepool_ready) next_state = avepool_busy;
			else if(maxpool_ready) next_state = maxpool_busy;
            else next_state = idle;
        end
        conv_busy: begin
            if(conv_burst_cnt == CONV_BURST_LEN) next_state = conv_clear;
            else next_state = conv_busy;
        end
		conv_clear: begin
			if(conv_finish) begin 
				next_state = finish;
			end else if (rdy_acc_0[0])begin
				next_state = conv_busy;
			end else begin
				next_state = conv_clear;
			end
		end
		maxpool_busy: begin
			if(pool_burst_cnt == POOL_BURST_LEN) next_state = maxpool_clear;
			else next_state = maxpool_busy;
		end
		maxpool_clear: begin
			if(maxpool_finish) begin
				next_state = finish;
			end else if (rdy_maxpool[0]) begin
				next_state = maxpool_busy;
			end else begin
				next_state = maxpool_clear;
			end
		end
		avepool_busy: begin
            if(pool_burst_cnt == POOL_BURST_LEN) next_state = avepool_clear;
            else next_state = avepool_busy;
        end
		avepool_clear: begin
			if(avepool_finish) begin 
				next_state = finish;
			end else if (rdy_avepool[0]) begin
				next_state = avepool_busy;
			end else begin
				next_state = avepool_clear;
			end
		end
		finish: begin
		end
        default:
            next_state = idle;
    endcase
end

//    Output, non-blocking
integer a;
//Synchronous Port 0 MUX logic
always @ (posedge clk or posedge rst) begin
	if(rst) begin
		conv_burst_cnt <= 0;
		pool_burst_cnt <= 0;
		conv_ready_0 <= 16'h0;
		conv_ready_1 <= 16'h0;
		avepool_ready_0 <= 0;
		maxpool_ready_0 <= 0;
		p0_data_fifo_rd_en <= 0;
		p1_data_fifo_rd_en <= 0;
		p0_weight_fifo_rd_en <= 0;
		p1_weight_fifo_rd_en <= 0;
		conv_valid <= 0;
		avepool_valid <= 0;
		maxpool_valid <= 0;
	end else begin
		for(a=0;a<CONV_BURST_LEN;a=a+1) begin: clear_conv_ready
			if(conv_valid_0[a]) conv_ready_0[a] <= 0;
		end
		for(a=0;a<POOL_BURST_LEN;a=a+1) begin: clear_avepool_ready
			if(avepool_valid_0[a]) avepool_ready_0[a] <= 0;
			if(maxpool_valid_0[a]) maxpool_ready_0[a] <= 0;
		end
		case (curr_state)
			idle: begin
			end
			conv_busy: begin
				case (op_type)
					CONV1: begin 
						conv_burst_cnt <= conv_burst_cnt + 1;
						conv_ready_1[conv_burst_cnt] <= 1; 
						if(conv_burst_cnt < 16) begin 
							p1_data_fifo_rd_en <= 1; 
							p1_weight_fifo_rd_en <= 1;
						end 
					end
					CONV3: begin 
						conv_burst_cnt <= conv_burst_cnt + 1;
						conv_ready_0[conv_burst_cnt] <= 1;
						if(conv_burst_cnt < 16) begin 
							p0_data_fifo_rd_en <= 1; 
							p0_weight_fifo_rd_en <= 1;
						end else begin
							p0_data_fifo_rd_en <= 0; 
							p0_weight_fifo_rd_en <= 0;
						end
					end
					CONVP: begin 
						conv_burst_cnt <= conv_burst_cnt + 1;
						conv_ready_0[conv_burst_cnt] <= 1; conv_ready_1[conv_burst_cnt] <= 1; 
						if(conv_burst_cnt < 16) begin 
							p0_data_fifo_rd_en <= 1; p0_weight_fifo_rd_en <= 1;
							p1_data_fifo_rd_en <= 1; p1_weight_fifo_rd_en <= 1; 
						end
					end
					default:;
				endcase
			end
			conv_clear: begin
				conv_burst_cnt <= 0;
			end
			maxpool_busy: begin
				case(op_type)
					MPOOL: begin
						pool_burst_cnt <= pool_burst_cnt + 1;
						maxpool_ready_0[pool_burst_cnt] <= 1;
						if(pool_burst_cnt < 1) begin
							p0_data_fifo_rd_en <= 1;
						end else begin
							p0_data_fifo_rd_en <= 0;
						end
					end
					default:;
				endcase
			end
			maxpool_clear: begin
				pool_burst_cnt <= 0;
			end
			avepool_busy: begin
				case (op_type)
					APOOL: begin
						pool_burst_cnt <= pool_burst_cnt + 1;
						avepool_ready_0[pool_burst_cnt] <= 1;
						if(pool_burst_cnt < 1) begin
							p0_data_fifo_rd_en <= 1;
						end else begin
							p0_data_fifo_rd_en <= 0;
						end
					end
					default: ;
				endcase
			end
			avepool_clear: begin
				pool_burst_cnt <= 0;
			end
			finish: begin
				case(op_type)
					CONV3:conv_valid <= 1;
					MPOOL:maxpool_valid <= 1;
					APOOL:avepool_valid <= 1;
					default:;
				endcase
			end
			default:;
		endcase
	end
end

integer b;
always@(posedge clk) begin
	if(!conv_ready) begin
		for(b=0;b<CONV_BURST_LEN;b=b+1) begin
			d0[b] <= 16'h0000; w0[b] <= 16'h0000;
			d1[b] <= 16'h0000; w1[b] <= 16'h0000;
			conv_count[b] <= op_num;
		end
	end else begin
		if(conv_burst_cnt >= 2 && conv_burst_cnt <= CONV_BURST_LEN + 1) begin
			d0[conv_burst_cnt-2] <= data_0;
			w0[conv_burst_cnt-2] <= weight_0;
			if(conv_count[conv_burst_cnt-2] != 0)
				conv_count[conv_burst_cnt-2] <= conv_count[conv_burst_cnt-2] - 1;
		end
	end
end

integer c;
always@(posedge clk) begin
	if(!avepool_ready) begin
		for(c=0;c<POOL_BURST_LEN;c=c+1) begin
			ap[c] <= 16'h0000;
			pool_count[c] <= op_num;
		end
	end else begin
		if(pool_burst_cnt >= 2 && pool_burst_cnt <= POOL_BURST_LEN + 1) begin
			ap[pool_burst_cnt-2] <= data_0;
			if(pool_count[pool_burst_cnt-2] != 0)
				pool_count[pool_burst_cnt-2] <= pool_count[pool_burst_cnt-2] - 1;
		end
	end
end

integer d;
always@(posedge clk) begin
	if(!maxpool_ready) begin
		for(d=0;d<POOL_BURST_LEN;d=d+1) begin
			mp[d] <= 16'h0000;
			pool_count[d] <= op_num;
		end
	end else begin
		if(pool_burst_cnt >= 2 && pool_burst_cnt <= POOL_BURST_LEN + 1) begin
			mp[pool_burst_cnt-2] <= data_0;
			if(pool_count[pool_burst_cnt-2] != 0)
				pool_count[pool_burst_cnt-2] <= pool_count[pool_burst_cnt-2] - 1;
		end
	end
end
//TODO: Merged Write back to csb
endmodule
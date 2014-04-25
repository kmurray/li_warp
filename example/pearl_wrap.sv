/*
 * Latency Insensitive Wrapper generated on Mon Mar  3 12:45:02 2014 for kmurray
 *
 * Command Line:
 *   ../li_wrap.pl -v pearl_clk_ena.sv -o pearl_wrap_clk_ena.sv -p 0 -f 2
 *
 */

module pearl_wrap #(
	parameter DWIDTH = 16,
	parameter FIFO_ADDR = 2
) (
	input  clk,
	input  reset,

	li_link.sink   i_data1_link,
	li_link.sink   i_data2_link,
	li_link.source o_data_link
);
	/*
	 * Delcarations
	 */
	//i_data1_link_buf delcarations
	wire w_i_data1_link_buf_bypass;
	wire [(DWIDTH)-1:0] w_i_data1_link_buf_data;
	reg c_i_data1_link_buf_enq;
	wire w_i_data1_link_buf_deq;
	wire w_i_data1_link_buf_full;
	wire w_i_data1_link_buf_empty;
	
	//i_data2_link_buf delcarations
	wire w_i_data2_link_buf_bypass;
	wire [(DWIDTH)-1:0] w_i_data2_link_buf_data;
	reg c_i_data2_link_buf_enq;
	wire w_i_data2_link_buf_deq;
	wire w_i_data2_link_buf_full;
	wire w_i_data2_link_buf_empty;
	
	//Control Logic delcarations
	wire w_inputs_valid;
	wire w_outputs_ok;
	wire w_fire;
	reg r_o_data_link_done;
	
	/*
	 * Bypassable input queue(s)
	 */
	li_input_buffer #(
		.WIDTH(DWIDTH),
		.ADDR(FIFO_ADDR)
	) i_data1_link_buf (
		.clk           (clk),
		.reset         (reset),
		.i_bypass      (w_i_data1_link_buf_bypass),
		.i_data        (i_data1_link.data),
		.o_data        (w_i_data1_link_buf_data),
		.i_enq         (c_i_data1_link_buf_enq),
		.i_deq         (w_i_data1_link_buf_deq),
		.o_full        (w_i_data1_link_buf_full),
		.o_almost_full (),
		.o_empty       (w_i_data1_link_buf_empty)
	);
	
	li_input_buffer #(
		.WIDTH(DWIDTH),
		.ADDR(FIFO_ADDR)
	) i_data2_link_buf (
		.clk           (clk),
		.reset         (reset),
		.i_bypass      (w_i_data2_link_buf_bypass),
		.i_data        (i_data2_link.data),
		.o_data        (w_i_data2_link_buf_data),
		.i_enq         (c_i_data2_link_buf_enq),
		.i_deq         (w_i_data2_link_buf_deq),
		.o_full        (w_i_data2_link_buf_full),
		.o_almost_full (),
		.o_empty       (w_i_data2_link_buf_empty)
	);
	
	/*
	 * The pearl
	 */
	pearl #(
		.DWIDTH (DWIDTH)
	) pearl (
		.clk (clk),
		.reset (reset),
		.clk_ena (w_fire),
		.i_data1 (w_i_data1_link_buf_data),
		.i_data2 (w_i_data2_link_buf_data),
		.o_data (o_data_link.data)
	);
	
	//Fire condition
	assign w_inputs_valid = ((i_data1_link.valid || !w_i_data1_link_buf_empty) && (i_data2_link.valid || !w_i_data2_link_buf_empty));
	assign w_outputs_ok = !((o_data_link.stop && o_data_link.valid));
	assign w_fire = w_inputs_valid && w_outputs_ok;
	
	//Output(s) valid
	always@(posedge clk or posedge reset) begin
		if(reset) begin
			r_o_data_link_done <= 1'b1;
		end else begin
			if(o_data_link.stop && r_o_data_link_done) begin
				r_o_data_link_done <= 1'b1;
			end else begin
				r_o_data_link_done <= w_fire;
			end
		end
	end
	assign o_data_link.valid = r_o_data_link_done;
	
	//Enq
	always@(*) begin
		casex({i_data1_link.valid, w_i_data1_link_buf_full, w_fire, w_i_data1_link_buf_empty})
			4'b100x: begin
				//Valid && not full && not fire
				c_i_data1_link_buf_enq <= 1'b1;
			end
			4'b10x0: begin
				//Valid && not full && not empty
				c_i_data1_link_buf_enq <= 1'b1;
			end
			default: begin
				c_i_data1_link_buf_enq <= 1'b0;
			end
		endcase
	end
	always@(*) begin
		casex({i_data2_link.valid, w_i_data2_link_buf_full, w_fire, w_i_data2_link_buf_empty})
			4'b100x: begin
				//Valid && not full && not fire
				c_i_data2_link_buf_enq <= 1'b1;
			end
			4'b10x0: begin
				//Valid && not full && not empty
				c_i_data2_link_buf_enq <= 1'b1;
			end
			default: begin
				c_i_data2_link_buf_enq <= 1'b0;
			end
		endcase
	end
	
	//Deq
	assign w_i_data1_link_buf_deq = !w_i_data1_link_buf_empty && w_fire;
	assign w_i_data2_link_buf_deq = !w_i_data2_link_buf_empty && w_fire;
	
	//Stop upstream
	assign i_data1_link.stop = w_i_data1_link_buf_full;
	assign i_data2_link.stop = w_i_data2_link_buf_full;
	
	//FIFO bypass
	assign w_i_data1_link_buf_bypass = w_i_data1_link_buf_empty;
	assign w_i_data2_link_buf_bypass = w_i_data2_link_buf_empty;
	
endmodule


module scdpram_infer #(
	parameter WIDTH=10,
	parameter ADDR=4
) (
	input clk,
	input [ADDR-1:0] i_rd_addr,
	input [ADDR-1:0] i_wr_addr,
	input [WIDTH-1:0] i_data,
	input i_wr_ena,
	output [WIDTH-1:0] o_data
);

	reg [WIDTH-1:0] mem [2**ADDR:0];
	
	reg [WIDTH-1:0] r_data_out;
	
	wire [ADDR-1:0] w_rd_addr;
	wire [ADDR-1:0] w_wr_addr;
	wire w_wr_ena;
	wire [WIDTH-1:0] w_data_in;
	
	//NOTE: blocking assignments -> new data read-during-write behaviour
	always@(posedge  clk) begin
		if(w_wr_ena) begin
			mem[w_wr_addr] = w_data_in;
		end
		
		r_data_out = mem[w_rd_addr];
	end

	
	assign w_data_in = i_data;
	assign w_wr_addr = i_wr_addr;
	assign w_wr_ena = i_wr_ena;
	assign w_rd_addr = i_rd_addr;

	assign o_data = r_data_out;
	

	




endmodule

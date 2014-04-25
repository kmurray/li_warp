#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long::Descriptive;
use Data::Dumper;
use Verilog::Netlist;

#
# Constants
#
my @NORMAL_PORTS = ('clk', 'reset');
my @CLK_ENA_PORTS = ('clk_ena');
my $clk_net = "clk";
my $reset_net = "reset";

my $li_link_sink = "li_link.sink  ";
my $li_link_source = "li_link.source";

my $inputs_valid_net = "w_inputs_valid";
my $outputs_ok_net = "w_outputs_ok";
my $fire_net = "w_fire";
my $fire_reg = "r_fire";
my $gated_clk = "w_gclk";

#
# Handle Options
#
my $cmd_line = $0;
foreach my $arg (@ARGV) {
    $cmd_line .= " " . $arg
}

my ($opt, $usage) = describe_options(
    '%c %o',
    ['verilog_file|v=s', 'The verilog file to parse.'],
    ['output_wrapper_file|o=s', 'The output wrapper file.', {default => 'wrapper.sv'}],
    ['merge_ports|m=s', 'A list of ports to merge. Format "porta,portb,portc;portd,porte;" will merge ports a b c into a single LI link, and ports d e into another LI link.', {default => ''}],
    ['pipeline|p=i', 'Number of extra pipeline stages the wrapper should use (either 0, 1 or 2). More stages should result in higher Fmax. Note: pipelined shell uses slightly different LI protocal from the default non-pipelined (0 stage) version.', {default => 0}],
    ['fifo_addr|f=i', 'The default FIFO_ADDR value. FIFO depth is 2^FIFO_ADDR. Default: 2.', {default => '2'}],
    ['help|h', 'Print usage message and exit'],
);

my $missing_args = 1;
if($opt->verilog_file && $opt->output_wrapper_file) {
    $missing_args = 0;
}

if($opt->help || $missing_args) {
    print "This script reads in a Verilog module description and generates a\n";
    print "latency-insensitive wrapper for it.\n";
    print "\n";
    print "It assumes the following signal naming conventions:\n";
    print "  Clock Net Name: '$clk_net'\n";
    print "  Reset Net Name: '$reset_net'\n";
    print "  Clock Enable Net Name(s): '@CLK_ENA_PORTS'\n";
    print "\n";
    print "If no net matching the clock enable net name(s) is found a gated\n";
    print "clock will be created. In this case you may wish to set your CAD\n";
    print "tool to infer clock gating as clock enables\n";


    print "\nUsage:\n";
    print $usage->text, "\n";
    exit;
}

if($opt->pipeline && ($opt->pipeline > 2 || $opt->pipeline < 0)) {
    printf("Invalid number of extra pipeline stages %d. Must be either 0, 1 or 2.\n\n", $opt->pipeline);
    print $usage->text, "\n";
    exit;
} else {
    printf("Generating wrapper with %d extra pipeline stages.\n", $opt->pipeline);

}


#
# Parse Verilog files
#

# Verilog parser options
use Verilog::Getopt;
my $vlog_opt = new Verilog::Getopt;
$vlog_opt->parameter();

# Prepare netlist
my $nl = new Verilog::Netlist (link_read=>0, link_read_nonfatal=>1);

#Read the file
$nl->read_file (filename=>$opt->verilog_file, link_read_nonfatal=>1);

# Read in any sub-modules
$nl->link();
$nl->exit_if_error();

#
# Determine which ports should be made LI
#

#Find the top module
my @top_modules = $nl->top_modules_sorted;
die("Found %d top level modules (should be one) $!\n", @top_modules) if (@top_modules != 1);
my $top_module = $top_modules[0];

#
# Create the new wrapper module
#

#Error Checks
my ($normal_ports, $clk_ena_ports, $unwrapped_ports) = identify_ports($top_module);
die("No ports to make LI found! $!\n") if (@$unwrapped_ports <= 0);

my $generate_clk_gater = 0;
if(@$clk_ena_ports > 1) {
    die("Found @$clk_ena_ports clk ena ports. Cound not resolve! $!\n");
} elsif (@$clk_ena_ports == 0) {
    print "Found no clock ena ports, will generate clock gating circuitry. MAY BE UNSAFE/DEGRADE PERFORMANCE. If possible have your synthesis tool convert gated clocks to clock enables.\n";
    $generate_clk_gater = 1;
}


my @decl_vlog_text = ();
my $indent = "\t";
push @decl_vlog_text, $indent . "/*\n";
push @decl_vlog_text, $indent . " * Delcarations\n";
push @decl_vlog_text, $indent . " */\n";

my ($port_li_link_map, $li_links) = convert_ports_to_li_links($unwrapped_ports, $opt->merge_ports);

my $wrapper_header = gen_module_header($cmd_line, $top_module, $normal_ports, $port_li_link_map);

my $wrapper_input_buffers = gen_input_buffers($indent, $top_module, $li_links, \@decl_vlog_text);

my $wrapper_cntrl_logic = gen_control_logic($indent, $top_module, $li_links, \@decl_vlog_text, $generate_clk_gater, $opt);

my $wrapper_pearl_inst = gen_pearl_instance($indent, $top_module, $normal_ports, $clk_ena_ports, $li_links, $generate_clk_gater, $opt);


#
# Write out the wrapper
#
printf("Writting generated wrapper to: %s\n", $opt->output_wrapper_file);
open(my $out_fh, "> ", $opt->output_wrapper_file);

#Print the header
for my $line (@$wrapper_header) {
    print $out_fh $line;
}

#Print the delcarations
for my $line (@decl_vlog_text) {
    print $out_fh $line;
}

#Print input queues
for my $line (@$wrapper_input_buffers) {
    print $out_fh $line;
}

#Print instantiation
for my $line (@$wrapper_pearl_inst) {
    print $out_fh $line;
}

#Print control logic
for my $line (@$wrapper_cntrl_logic) {
    print $out_fh $line;
}

#End of module
print $out_fh "endmodule\n\n";


close($out_fh);
print "Done!\n";
exit(0);


sub gen_pearl_instance {
    my ($indent, $top_module, $normal_ports, $clk_ena_ports, $li_links, $generate_clk_gater, $opt) = @_;
    
    my @vlog_text = ();

    push @vlog_text, $indent . "/*\n";
    push @vlog_text, $indent . " * The pearl\n";
    push @vlog_text, $indent . " */\n";

    push @vlog_text, $indent . sprintf("%s #(\n", $top_module->name);

    my @params = identify_params($top_module);
    my $param_cnt = @params;
    my $iter_cnt = 0;
    foreach my $param (@params) {
        $iter_cnt++;
        my $param_connection = $indent . $indent . sprintf(".%s (%s)", $param->name, $param->name);
        $param_connection .= "," unless($iter_cnt == $param_cnt);
        $param_connection .= "\n";

        push @vlog_text, $param_connection;
    }

    push @vlog_text, $indent . sprintf(") pearl (\n");


    #Regular ports
    foreach my $port (@$normal_ports) {
        my $port_connection;
        if($generate_clk_gater && $port->name eq $clk_net) {
            #Use the gated clock
            $port_connection = sprintf(".%s (%s),\n", $port->name, $gated_clk);
        } else {
            #Normal straight through connection
            $port_connection = sprintf(".%s (%s),\n", $port->name, $port->name);
        }
        push @vlog_text, $indent . $indent . $port_connection;
    }

    #Clk ena
    if(!$generate_clk_gater) {
        if($opt->pipeline > 0) {
            push @vlog_text, $indent . $indent . sprintf(".%s (%s),\n", $clk_ena_ports->[0]->name, $fire_reg);
        } else {
            push @vlog_text, $indent . $indent . sprintf(".%s (%s),\n", $clk_ena_ports->[0]->name, $fire_net);
        }
    }

    my $li_link_count = @$li_links;
    my $li_link_iter = 0;
    foreach my $li_link (@$li_links) {
        $li_link_iter++;
        my $li_link_ports = $li_link->get_ports();

        my $link_port_count = @$li_link_ports;
        my $link_port_iter = 0;

        my $link_nets = $li_link->get_nets();

        my $port_ranges = $li_link->get_port_ranges();

        foreach my $port (@$li_link_ports) {
            $link_port_iter++;
            my $port_connection;
            
            my $range = $port_ranges->{$port};

            if($li_link->get_type() eq $li_link_sink) {
                if($opt->pipeline > 0) {
                    $port_connection = sprintf(".%s (%s%s)", $port->name, $link_nets->{'buff_out_data_reg'}, $range);
                } else {
                    $port_connection = sprintf(".%s (%s%s)", $port->name, $link_nets->{'buff_out_data'}, $range);
                }

            } else {
                $port_connection = sprintf(".%s (%s%s)", $port->name, $link_nets->{'link_data'}, $range);

            }

            $port_connection .= "," unless ($li_link_count == $li_link_iter && $link_port_count == $link_port_iter); #No comma on last line
            $port_connection .= "\n";

            push @vlog_text, $indent . $indent . $port_connection;

        }
    }

    push @vlog_text, $indent . ");\n";
    push @vlog_text, $indent . "\n";


    return \@vlog_text;
}

sub gen_control_logic {
    my ($indent, $top_module, $li_links, $decl_vlog_text, $generate_clk_gater, $opt) = @_;

    my @vlog_text = ();
    
    push @$decl_vlog_text, $indent . "//Control Logic delcarations\n";

    #
    # Stop register
    #
    if($opt->pipeline > 1) {

        push @vlog_text, $indent . "//Output Channle Stop Register(s)\n";

        foreach my $li_link (@$li_links) {
            my $li_link_nets = $li_link->get_nets();
            my $link_name = $li_link->get_name();

            if($li_link->get_type() eq $li_link_source) {
                #Declare the stop register for each output link
                push @$decl_vlog_text, $indent . "reg $li_link_nets->{'link_stop'};\n";

                push @vlog_text, $indent . "always@(posedge $clk_net or posedge $reset_net) begin\n";
                push @vlog_text, $indent . $indent . "if($reset_net) begin\n";
                push @vlog_text, $indent . $indent . $indent . "$li_link_nets->{'link_stop'} <= 1'b0;\n";
                push @vlog_text, $indent . $indent . "end else begin\n";
                push @vlog_text, $indent . $indent . $indent . "$li_link_nets->{'link_stop'} <= $link_name.stop;\n";
                push @vlog_text, $indent . $indent . "end\n";
                push @vlog_text, $indent . "end\n";
                push @vlog_text, $indent . "\n";
            }
        }
    }

    #
    # Fire logic
    #
    push @$decl_vlog_text, $indent . "wire $inputs_valid_net;\n";
    push @$decl_vlog_text, $indent . "wire $outputs_ok_net;\n";
    push @$decl_vlog_text, $indent . "wire $fire_net;\n";
    if($generate_clk_gater) {
        push @$decl_vlog_text, $indent . "wire $gated_clk;\n";
        
    }

    if($opt->pipeline > 0) {
        push @$decl_vlog_text, $indent . "reg $fire_reg;\n";
    }
    

    my $inputs_valid_assign = "assign $inputs_valid_net = ("; 
    my $outputs_ok_assign = "assign $outputs_ok_net = !("; 

    my $first_input_iter = 1;
    my $first_output_iter = 1;
    foreach my $li_link (@$li_links) {
        my $li_link_nets = $li_link->get_nets();
        
        if($li_link->get_type() eq $li_link_sink) {
            $inputs_valid_assign .= " && " unless $first_input_iter == 1;
            $inputs_valid_assign .= "($li_link_nets->{'link_valid'} || !$li_link_nets->{'empty'})"; 
            $first_input_iter = 0;
        } else {
            $outputs_ok_assign .= " || " unless $first_output_iter == 1;

            if($opt->pipeline > 0) {
                $outputs_ok_assign .= "($li_link_nets->{'link_stop'})"; 

            } else {
                $outputs_ok_assign .= "($li_link_nets->{'link_stop'} && $li_link_nets->{'link_valid'})"; 
            }

            $first_output_iter = 0;
        }
    }
    $inputs_valid_assign .= ");\n";
    $outputs_ok_assign .= ");\n";

    my $fire_assign = "assign $fire_net = $inputs_valid_net && $outputs_ok_net;\n"; 

    push @vlog_text, $indent . "//Fire condition\n";
    push @vlog_text, $indent . $inputs_valid_assign;
    push @vlog_text, $indent . $outputs_ok_assign;
    push @vlog_text, $indent . $fire_assign;
    if($generate_clk_gater) {
        my $gated_clk_assign;
        if($opt->pipeline > 0) {
            $gated_clk_assign = "assign $gated_clk = $fire_reg & $clk_net;\n"; 
        } else {
            $gated_clk_assign = "assign $gated_clk = $fire_net & $clk_net;\n"; 
        }
        push @vlog_text, $indent . $gated_clk_assign;
    }
    push @vlog_text, $indent . "\n";

    if($opt->pipeline > 0) {
        push @vlog_text, $indent . "always@(posedge $clk_net or posedge $reset_net) begin\n";
        push @vlog_text, $indent . $indent . "if($reset_net) begin\n";
        push @vlog_text, $indent . $indent . $indent . "$fire_reg <= 1'b1;\n";
        push @vlog_text, $indent . $indent . "end else begin\n";
        push @vlog_text, $indent . $indent . $indent . "$fire_reg <= w_fire;\n";
        push @vlog_text, $indent . $indent . "end\n";
        push @vlog_text, $indent . "end\n";
        push @vlog_text, $indent . "\n";
    }

    #
    # Output Valid
    #

    push @vlog_text, $indent . "//Output(s) valid\n";
    foreach my $li_link (@$li_links) {
        my $li_link_nets = $li_link->get_nets();

        if($li_link->get_type eq $li_link_source) {
            my $link_name = $li_link->get_name();

            my $valid_reg;

            if($opt->pipeline > 0) {
                #Pipelined version
                my $orig_valid_reg = "r_${link_name}_done";
                $valid_reg = "r_${link_name}_done_delay1";
                
                #Declare the registers
                push @$decl_vlog_text, $indent . "reg $orig_valid_reg;\n";
                push @$decl_vlog_text, $indent . "reg $valid_reg;\n";

                #Define the register behaviour
                push @vlog_text, $indent . "always@(posedge $li_link_nets->{'clk'} or posedge $li_link_nets->{'reset'}) begin\n";
                push @vlog_text, $indent . $indent . "if($li_link_nets->{'reset'}) begin\n";
                push @vlog_text, $indent . $indent . $indent . "$orig_valid_reg <= 1'b1;\n";
                push @vlog_text, $indent . $indent . $indent . "$valid_reg <= 1'b0;\n";
                push @vlog_text, $indent . $indent . "end else begin\n";
                push @vlog_text, $indent . $indent . $indent . "if(!$li_link_nets->{'link_stop'}) begin\n";
                push @vlog_text, $indent . $indent . $indent . $indent . "$orig_valid_reg <= $fire_net;\n";
                push @vlog_text, $indent . $indent . $indent . "end else begin\n";
                push @vlog_text, $indent . $indent . $indent . $indent . "$orig_valid_reg <= 1'b0;\n";
                push @vlog_text, $indent . $indent . $indent . "end\n";
                push @vlog_text, $indent . $indent . $indent . "//Pipeline for one cycle to match datapath\n";
                push @vlog_text, $indent . $indent . $indent . "$valid_reg <= $orig_valid_reg;\n";
                push @vlog_text, $indent . $indent . "end\n";
                push @vlog_text, $indent . "end\n";

            } else {
                #Non-pipelined version
                $valid_reg = "r_${link_name}_done";

                #Declare the register
                push @$decl_vlog_text, $indent . "reg $valid_reg;\n";

                #Define the register behaviour
                push @vlog_text, $indent . "always@(posedge $li_link_nets->{'clk'} or posedge $li_link_nets->{'reset'}) begin\n";
                push @vlog_text, $indent . $indent . "if($li_link_nets->{'reset'}) begin\n";
                push @vlog_text, $indent . $indent . $indent . "$valid_reg <= 1'b1;\n";
                push @vlog_text, $indent . $indent . "end else begin\n";
                push @vlog_text, $indent . $indent . $indent . "if($li_link_nets->{'link_stop'} && $valid_reg) begin\n";
                push @vlog_text, $indent . $indent . $indent . $indent . "$valid_reg <= 1'b1;\n";
                push @vlog_text, $indent . $indent . $indent . "end else begin\n";
                push @vlog_text, $indent . $indent . $indent . $indent . "$valid_reg <= $fire_net;\n";
                push @vlog_text, $indent . $indent . $indent . "end\n";
                push @vlog_text, $indent . $indent . "end\n";
                push @vlog_text, $indent . "end\n";
            }

            #Assign the output
            push @vlog_text, $indent . "assign $li_link_nets->{'link_valid'} = $valid_reg;\n";
            push @vlog_text, $indent . "\n";
        }
    }
    push @$decl_vlog_text, $indent . "\n";
    
    #
    # Enq
    #
    push @vlog_text, $indent . "//Enq\n";
    foreach my $li_link (@$li_links) {
        my $li_link_nets = $li_link->get_nets();

        if($li_link->get_type() eq $li_link_sink) {
                #The original version, using an assign block
                #push @vlog_text, $indent . "assign $li_link_nets->{'enq'} = $li_link_nets->{'link_valid'} && (!$fire_net || !$li_link_nets->{'empty'}) && !$li_link_nets->{'full'};\n";
            #Fast version based on casex statement
            push @vlog_text, $indent . "always@(*) begin\n";
            if($opt->pipeline > 0) {
                push @vlog_text, $indent . $indent . "casex({$li_link_nets->{'link_valid'}, $li_link_nets->{'almost_full'}, $li_link_nets->{'full'}, $fire_net, $li_link_nets->{'empty'}})\n";
                push @vlog_text, $indent . $indent . $indent . "5'b1000x: begin\n";
                push @vlog_text, $indent . $indent . $indent . $indent . "//Valid && not almost full && not full && not fire\n";
                push @vlog_text, $indent . $indent . $indent . $indent . "$li_link_nets->{'enq'} <= 1'b1;\n";
                push @vlog_text, $indent . $indent . $indent . "end\n";
                push @vlog_text, $indent . $indent . $indent . "5'b100x0: begin\n";
                push @vlog_text, $indent . $indent . $indent . $indent . "//Valid && not almost full && not full && not empty\n";
                push @vlog_text, $indent . $indent . $indent . $indent . "$li_link_nets->{'enq'} <= 1'b1;\n";
                push @vlog_text, $indent . $indent . $indent . "end\n";
                push @vlog_text, $indent . $indent . $indent . "5'b110xx: begin\n";
                push @vlog_text, $indent . $indent . $indent . $indent . "//Valid && almost full && not full\n";
                push @vlog_text, $indent . $indent . $indent . $indent . "$li_link_nets->{'enq'} <= 1'b1;\n";
                push @vlog_text, $indent . $indent . $indent . "end\n";
                push @vlog_text, $indent . $indent . $indent . "default: begin\n";
                push @vlog_text, $indent . $indent . $indent . $indent . "$li_link_nets->{'enq'} <= 1'b0;\n";
                push @vlog_text, $indent . $indent . $indent . "end\n";
                push @vlog_text, $indent . $indent . "endcase\n";
            } else {
                push @vlog_text, $indent . $indent . "casex({$li_link_nets->{'link_valid'}, $li_link_nets->{'full'}, $fire_net, $li_link_nets->{'empty'}})\n";
                push @vlog_text, $indent . $indent . $indent . "4'b100x: begin\n";
                push @vlog_text, $indent . $indent . $indent . $indent . "//Valid && not full && not fire\n";
                push @vlog_text, $indent . $indent . $indent . $indent . "$li_link_nets->{'enq'} <= 1'b1;\n";
                push @vlog_text, $indent . $indent . $indent . "end\n";
                push @vlog_text, $indent . $indent . $indent . "4'b10x0: begin\n";
                push @vlog_text, $indent . $indent . $indent . $indent . "//Valid && not full && not empty\n";
                push @vlog_text, $indent . $indent . $indent . $indent . "$li_link_nets->{'enq'} <= 1'b1;\n";
                push @vlog_text, $indent . $indent . $indent . "end\n";
                push @vlog_text, $indent . $indent . $indent . "default: begin\n";
                push @vlog_text, $indent . $indent . $indent . $indent . "$li_link_nets->{'enq'} <= 1'b0;\n";
                push @vlog_text, $indent . $indent . $indent . "end\n";
                push @vlog_text, $indent . $indent . "endcase\n";
            }
            push @vlog_text, $indent . "end\n";
        }
    }
    push @vlog_text, $indent . "\n";
    
    #
    # Deq 
    #
    push @vlog_text, $indent . "//Deq\n";
    foreach my $li_link (@$li_links) {
        my $li_link_nets = $li_link->get_nets();

        if($li_link->get_type() eq $li_link_sink) {
            push @vlog_text, $indent . "assign $li_link_nets->{'deq'} = !$li_link_nets->{'empty'} && $fire_net;\n";
        }
    }
    push @vlog_text, $indent . "\n";

    #
    # Stop upstream
    #
    push @vlog_text, $indent . "//Stop upstream\n";
    foreach my $li_link (@$li_links) {
        my $li_link_nets = $li_link->get_nets();

        if($li_link->get_type() eq $li_link_sink) {
            if($opt->pipeline > 0) {
                push @vlog_text, $indent . "assign $li_link_nets->{'link_stop'} = $li_link_nets->{'almost_full'};\n";
            } else {
                push @vlog_text, $indent . "assign $li_link_nets->{'link_stop'} = $li_link_nets->{'full'};\n";
            }
        }
    }
    push @vlog_text, $indent . "\n";
    
    #
    # FIFO bypass
    #
    push @vlog_text, $indent . "//FIFO bypass\n";
    foreach my $li_link (@$li_links) {
        my $li_link_nets = $li_link->get_nets();

        if($li_link->get_type() eq $li_link_sink) {
            push @vlog_text, $indent . "assign $li_link_nets->{'bypass'} = $li_link_nets->{'empty'};\n";
        }
    }
    push @vlog_text, $indent . "\n";

    return \@vlog_text;
}


sub gen_input_buffers {
    my ($indent, $top_module, $li_links, $decl_vlog_text) = @_;
    
    my @vlog_text = ();

    push @vlog_text, $indent . "/*\n";
    push @vlog_text, $indent . " * Bypassable input queue(s)\n";
    push @vlog_text, $indent . " */\n";
    
    foreach my $li_link (@$li_links) {

        if($li_link->get_type() eq $li_link_sink) {
            #Determine the net width
            my $width = $li_link->get_link_width();
            
            #Instance name
            my $buff_name = $li_link->get_name() . '_buf';
            
            #Params and derived values
            my $addr = "FIFO_ADDR";
            my $width_bus = " [($width)-1:0]";
            if($width eq "1") {
                $width_bus = "";
            }

            #Nets
            my $link_nets = {'clk' => 'clk',
                             'reset' => 'reset',
                             'bypass' => "w_${buff_name}_bypass",
                             'link_data' => $li_link->get_name() . '.data',
                             'link_valid' => $li_link->get_name() . '.valid',
                             'link_stop' => $li_link->get_name() . '.stop',
                             'buff_out_data' => "w_${buff_name}_data",
                             'buff_out_data_reg' => "r_${buff_name}_data",
                             'enq' => "c_${buff_name}_enq",
                             'deq' => "w_${buff_name}_deq",
                             'full' => "w_${buff_name}_full",
                             'empty' => "w_${buff_name}_empty"};

            if($opt->pipeline > 0) {
                $link_nets->{'almost_full'} = "w_${buff_name}_almost_full";
            }

            #The buffer's connecting wire declarations
            push @$decl_vlog_text, $indent . "//$buff_name delcarations\n";
            push @$decl_vlog_text, $indent . "wire $link_nets->{'bypass'};\n";
            push @$decl_vlog_text, $indent . "wire$width_bus $link_nets->{'buff_out_data'};\n";
            if($opt->pipeline > 0) {
                push @$decl_vlog_text, $indent . "reg$width_bus $link_nets->{'buff_out_data_reg'};\n";
            }
            push @$decl_vlog_text, $indent . "reg $link_nets->{'enq'};\n";
            push @$decl_vlog_text, $indent . "wire $link_nets->{'deq'};\n";
            push @$decl_vlog_text, $indent . "wire $link_nets->{'full'};\n";
            if($opt->pipeline > 0) {
                push @$decl_vlog_text, $indent . "wire $link_nets->{'almost_full'};\n";
            }
            push @$decl_vlog_text, $indent . "wire $link_nets->{'empty'};\n";
            push @$decl_vlog_text, $indent . "\n";


            #The buffer instantiation
            push @vlog_text, $indent . "li_input_buffer #(\n";
            push @vlog_text, $indent . "\t.WIDTH($width),\n";
            push @vlog_text, $indent . "\t.ADDR($addr)\n"; #Last, no comma
            push @vlog_text, $indent . ") $buff_name (\n";
            push @vlog_text, $indent . "\t.clk           ($link_nets->{'clk'}),\n";
            push @vlog_text, $indent . "\t.reset         ($link_nets->{'reset'}),\n";
            push @vlog_text, $indent . "\t.i_bypass      ($link_nets->{'bypass'}),\n";
            push @vlog_text, $indent . "\t.i_data        ($link_nets->{'link_data'}),\n";
            push @vlog_text, $indent . "\t.o_data        ($link_nets->{'buff_out_data'}),\n";
            push @vlog_text, $indent . "\t.i_enq         ($link_nets->{'enq'}),\n";
            push @vlog_text, $indent . "\t.i_deq         ($link_nets->{'deq'}),\n";
            push @vlog_text, $indent . "\t.o_full        ($link_nets->{'full'}),\n";
            if($opt->pipeline > 0) {
                push @vlog_text, $indent . "\t.o_almost_full ($link_nets->{'almost_full'}),\n";
            } else {
                push @vlog_text, $indent . "\t.o_almost_full (),\n";
            }
            push @vlog_text, $indent . "\t.o_empty       ($link_nets->{'empty'})\n";
            push @vlog_text, $indent . ");\n";
            push @vlog_text, $indent . "\n";

            #The output register
            if($opt->pipeline > 0) {
                push @vlog_text, $indent . "always@(posedge $link_nets->{'clk'} or posedge $link_nets->{'reset'}) begin\n";
                push @vlog_text, $indent . $indent . "if($link_nets->{'reset'}) begin\n";
                push @vlog_text, $indent . $indent . $indent . "$link_nets->{'buff_out_data_reg'} <= {($width) {1'b0}};\n";
                push @vlog_text, $indent . $indent . "end else begin\n";
                push @vlog_text, $indent . $indent . $indent . "$link_nets->{'buff_out_data_reg'} <= $link_nets->{'buff_out_data'};\n";
                push @vlog_text, $indent . $indent . "end\n";
                push @vlog_text, $indent . "end\n";
                push @vlog_text, $indent . "\n";
            }

            # Save the delcared nets for use with the control logic
            $li_link->add_nets($link_nets);
        } else {
            my $link_nets = {'clk' => 'clk',
                             'reset' => 'reset',
                             'link_data' => $li_link->get_name() . '.data',
                             'link_valid' => $li_link->get_name() . '.valid',
                             'link_stop' => $li_link->get_name() . '.stop'};
            
            if($opt->pipeline > 1) {
                #Overwrite previous value, since the used signal is now registered
                $link_nets->{'link_stop'} = "r_" . $li_link->get_name() . "_stop";
            }

            # Save the delcared nets for use with the control logic
            $li_link->add_nets($link_nets);
        }
    }

    return \@vlog_text;
}

sub gen_module_header {
    my ($cmd_line, $top_module, $normal_ports, $port_li_link_map) = @_;

    my @header = ();

    my $date = localtime;
    my $user = $ENV{LOGNAME} || $ENV{USER} || getpwuid($<);

    push @header, sprintf("/*\n");
    push @header, sprintf(" * Latency Insensitive Wrapper generated on $date for $user\n");
    push @header, sprintf(" *\n");
    push @header, sprintf(" * Command Line:\n");
    push @header, sprintf(" *   $cmd_line\n");
    push @header, sprintf(" *\n");
    push @header, sprintf(" */\n");
    push @header, sprintf("\n");

    #Header
    #push @header, sprintf("module li_%s_wrapper #(\n", $top_module->name); #Name based on top module
    push @header, sprintf("module %s #(\n", $opt->output_wrapper_file =~ /(\w+).sv/); #Name based on output filename

    #Print params
    #Params in the original module
    my @params = identify_params($top_module);

    foreach my $param (@params) {
        push @header, sprintf("\tparameter %s = %s,\n", $param->name, $param->value);
    }
    #Add the FIFO depth param
    my $fifo_addr_param = new Verilog::Netlist::Net('name'=>'FIFO_ADDR', 'value'=>$opt->fifo_addr);
    #No comma, since last param!
    push @header, sprintf("\tparameter %s = %s\n", $fifo_addr_param->name, $fifo_addr_param->value);

    #End of params/Start of port list
    push @header, ") (\n";

    #Regular ports, no re-naming
    foreach my $port (@$normal_ports) {
        push @header, sprintf("\t%sput %s %s,\n", $port->direction, $port->data_type, $port->name);
    }

    #Extra space
    push @header, sprintf("\n");

    my $iter_count = 0;
    my $link_count = @$li_links;
    foreach my $li_link (@$li_links) {
        $iter_count++;

        my $port_str = sprintf("\t%s %s", $li_link->get_type(), $li_link->get_name());

        $port_str .= "," unless($iter_count == $link_count); #No last comma
        $port_str .= "\n";

        push @header, $port_str;
    }

    #End of module declaration
    push @header, sprintf(");\n");

    return \@header
}


sub convert_ports_to_li_links {
    my ($ports, $merge_ports_str) = @_;

    my $merge_port_map = interpret_merge_port_str($merge_ports_str);

    my %merged_link_name_map = (); #Stores mapping from link name to link object
    my %port_li_link_map = ();
    my @li_links;

    foreach my $port (@$ports) {
        my $type;
        if($port->direction eq "in") {
            $type = $li_link_sink;
        } elsif ($port->direction eq "out") {
            $type .= $li_link_source;
        } else {
            die("Unsupported port direction '%s' in port '%s' $!", $port->direction, $port->name);
        }

        my $li_link_obj;

        if(exists $merge_port_map->{$port->name}) {
            my $merged_link_name = $merge_port_map->{$port->name};
            #This port is being merged into a composite link

            #Check if the composite link already exists
            if(exists $merged_link_name_map{$merged_link_name}) {
                $li_link_obj = $merged_link_name_map{$merged_link_name};

                my $li_link_type = $li_link_obj->get_type();
                die("LiLink types %s and %s do not match\n", $type, $li_link_type) unless ($type eq $li_link_type);

                #Add this port too it
                $li_link_obj->add_port($port);
            } else {
                #Create it
                $li_link_obj = new LiLink($merged_link_name, $type, $top_module);
                push(@li_links, $li_link_obj);

                #Add the port
                $li_link_obj->add_port($port);

                #Reverse look-up
                $merged_link_name_map{$merged_link_name} = $li_link_obj;
            }
        } else {
            #This port is converted to a unique link

            my $name = $port->name . "_link";

            $li_link_obj = new LiLink($name, $type, $top_module);
            $li_link_obj->add_port($port);
            push(@li_links, $li_link_obj);


        }
        $port_li_link_map{$port->name} = {'link' => $li_link_obj};

    }

    return (\%port_li_link_map, \@li_links);
}

sub interpret_merge_port_str {
    my ($merge_port_str) = @_;

    my %merged_port_map = ();
    my %merged_link_map = ();

    #Semi-colons divide merged port def'ns
    my @merged_ports = split(/;/, $merge_port_str);

    foreach my $port_str (@merged_ports) {
        #Each port is sperated by a comma
        my @port_list = split(/,/, $port_str);
    

        my $merged_port_name = join('_', @port_list, "link");
        
        printf("Merging ports {" . join(",", @port_list) . "} into link: " . $merged_port_name . "\n");

        for my $port_name (@port_list) {
            $merged_port_map{$port_name} = $merged_port_name;
        }
    }

    return \%merged_port_map;
}

sub identify_params {
    my ($top_module) = @_;

    #Identify parameters from original modules
    my @params = ();
    foreach my $net ($top_module->nets) {
        if($net->decl_type eq 'parameter') {
            push @params, ($net);
        }
    }

    return @params;
}

sub identify_ports {
    my ($top_module) = @_;
    my @unwrapped_ports = ();
    my @normal_ports = ();
    my @clk_ena_ports;
    foreach my $port ($top_module->ports_sorted) {
        #Check if port is in the skip list
        my $skip = 0;
        foreach my $normal_port (@NORMAL_PORTS) {
            if ($port->name eq $normal_port) {
                $skip = 1;
                push @normal_ports, $port;
                last;
            }
        }
        foreach my $clk_ena_port (@CLK_ENA_PORTS) {
            if($port->name eq $clk_ena_port) {
                $skip = 1;
                push @clk_ena_ports, $port;
                last;
            }
        }
        next if($skip);

        #Add this port to the list
        push @unwrapped_ports, $port;
    }

    return (\@normal_ports, \@clk_ena_ports, \@unwrapped_ports);
}

package LiLink;

sub new {
    my ($class, $name, $type, $top_module) = @_;
    my $self = {
                'type' => $type,
                'name' => $name,
                'orig_ports' => [],
                'top_module' => $top_module,
                };
    return bless($self, $class);
}

sub add_port {
    my ($self, $port) = @_;
    push(@{$self->{'orig_ports'}}, $port);
}

sub add_nets {
    my ($self, $nets) = @_;
    $self->{'nets'} = $nets;
}

sub get_type {
    my ($self) = @_;
    return $self->{'type'};
}

sub get_name {
    my ($self) = @_;
    return $self->{'name'};
}

sub get_nets {
    my ($self) = @_;
    return $self->{'nets'};
}

sub get_link_width {
    my ($self) = @_;
    
    my $width = "";

    my $first_iter = 1;
    foreach my $port (@{$self->get_ports()}) {

        $width .= "+" unless($first_iter);

        $first_iter = 0;

        my $port_width = $self->get_port_width($port);

        $width .= $port_width;
    }

    return $width;

}

sub get_port_width {
    my ($self, $port) = @_;

    my $top_module = $self->{'top_module'};

    my $net = $top_module->find_net($port->name);

    my $width;
    if(!defined($net->lsb) && !defined($net->msb) && !defined($net->width)) {
        $width = "1";
    } elsif(defined($net->lsb) && defined($net->msb)) {
        #printf("\tlsb: %s, msb: %s, width: %s\n", $net->lsb, $net->msb, $net->width);

        if($net->msb =~ /(\S+)-1/ && $net->lsb eq "0") {
            $width = $1;
        } else {
            die("Could not resolve width, lsb: $net->lsb, msb: $net->msb\n");
        }

    } else {
        die("Unkown width for net " . $net->name . "\n");
    }
    return $width;
}

sub get_port_ranges {
    my ($self) = @_;

    my %port_ranges = ();
    my $ports = $self->get_ports();

    if(scalar @{$ports} == 1) {
        #Single port, don't need to specify range
        foreach my $port (@{$self->{'orig_ports'}}) {
            $port_ranges{$port} = "";
        }

    } else {
        #Multiple ports, do need to specify range
        my $curr_lsb = "0";
        foreach my $port (@{$self->{'orig_ports'}}) {
            my $port_width = $self->get_port_width($port);

            my $range;

            my $curr_msb = "";
            if ($curr_lsb eq "0") {
                $curr_msb = "$port_width-1";
            } else {
                $curr_msb = "$port_width-1+$curr_lsb";
            }

            if($port_width eq "1") {
                $range = "[$curr_lsb]";
            } else {
                $range = "[$curr_msb:$curr_lsb]";
            }

            $port_ranges{$port} = $range;

            if ($curr_lsb eq "0") {
                $curr_lsb = "$port_width";
            } else {
                $curr_lsb = "$port_width+$curr_lsb";
            }
        }
    }


    return \%port_ranges;
}

sub get_ports {
    my ($self, $port_to_match) = @_;
    return $self->{'orig_ports'};
}

sub sprint {
    my ($self) = @_;

    my $str = sprintf("type: %s, name: %s ports: [", $self->{'type'}, $self->{'name'});
    foreach my $port (@{$self->{'orig_ports'}}) {
        $str .= sprintf("%s, ", $port->name);
    }
    $str .= sprintf("]\n");
}

sub print {
    my ($self) = @_;

    print $self->sprint();
}

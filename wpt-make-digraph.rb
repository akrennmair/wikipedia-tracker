#!/usr/bin/env ruby
# wpt-make-digraph.rb - this script produces .dot files from the wp-tracker-proxy
# CSV output files to be processed with graphviz.
#
# ----------------------------------------------------------------------------
# "THE BEER-WARE LICENSE" (Revision 42):
# Andreas Krennmair <ak@synflood.at> wrote this program.	As long as you retain
# this notice you can do whatever you want with this stuff. If we meet some day, 
# and you think this stuff is worth it, you can buy me a beer in return.
#	 -- Andreas Krennmair <ak@synflood.at>
# ----------------------------------------------------------------------------
#

if ARGV.size < 1 then
	$stderr.puts("#{$0}: usage: #{$0} <file> ...")
	Kernel.exit(1)
end

aof = File.open("all.dot", "w+")
aof.puts("digraph wptgraph {")

ARGV.each do |fn|

	File.open(fn) do |f|
		ofn = "#{fn}.dot"
		File.open(ofn, "w+") do |of|
			of.puts("digraph wptdigraph {")
			f.each_line do |l|
				fields = l.chomp.split(/;/)
				if fields.size >= 2 then
					of.puts("\"#{fields[0]}\" -> \"#{fields[1]}\";")
					lang = fn.split(/\./)[0]
					aof.puts("\"#{fields[0]}\" -> \"#{fields[1]}\" [group=#{lang}];")
				end
			end
			of.puts("}")
		end
		$stderr.puts("generated #{ofn}")
	end

end

aof.puts("}")
aof.close

vcs -full64 -timescale=1ns/1ps -sverilog -f filelist.f \
    -debug_access+pp+all -kdb -lca +vpi \
    +define+FSDB \
    -o simv

./simv
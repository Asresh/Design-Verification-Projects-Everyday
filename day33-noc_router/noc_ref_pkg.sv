package noc_ref_pkg;
    parameter int NPORT = 3;
    parameter int FLIT_W = 32;
    typedef struct packed {
        logic [1:0] src;
        logic [1:0] dst;
        logic [FLIT_W-1:0] data;
        logic last;
    } noc_ref_flit_t;

    function automatic int route(input int dst);
        return dst;
    endfunction

    function automatic bit source_tag_ok(input int src,
                                          input logic [FLIT_W-1:0] data);
        return data[FLIT_W-1 -: 2] == src[1:0];
    endfunction

    task automatic ref_selfcheck;
        for (int d=0; d<NPORT; d++)
            if (route(d) != d) $fatal(1, "reference route self-check failed");
        for (int s=0; s<NPORT; s++) begin
            logic [FLIT_W-1:0] v;
            v = '0;
            v[FLIT_W-1 -: 2] = s[1:0];
            if (!source_tag_ok(s, v)) $fatal(1, "source tag self-check failed");
        end
    endtask
endpackage

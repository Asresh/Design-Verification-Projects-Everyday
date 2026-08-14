// Author: Asresh Kuricheti
package tlb_ref_pkg;
    parameter int VA_W=32, PA_W=32, ASID_W=8, ENTRIES=8;
    typedef enum bit [1:0] {TLB_QUERY,TLB_FILL,TLB_INVALIDATE} tlb_op_e;
    function automatic bit page_matches(bit [VA_W-1:0] a, bit [VA_W-1:0] b, bit superpage);
        return superpage ? (a[VA_W-1:21] == b[VA_W-1:21]) : (a[VA_W-1:12] == b[VA_W-1:12]);
    endfunction
    function automatic bit [PA_W-1:0] translate(bit [PA_W-1:0] base, bit [VA_W-1:0] va, bit superpage);
        return superpage ? {base[PA_W-1:21],va[20:0]} : {base[PA_W-1:12],va[11:0]};
    endfunction
endpackage

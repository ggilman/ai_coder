#!/bin/bash
# ==============================================================================
# AI-CODER-GGUF.SH | GGUF metadata reader and per-tier KV cache geometry
# ==============================================================================
# Sourced by ai-coder-core.sh after ai-coder-model.sh — not run standalone.
#
# KV cache size is fixed by a model's architecture (layers x KV heads x head
# dim, sliding-window layout, MLA), not by its weight quant, and a family's
# tiers usually mix several base models. The GGUF metadata header records
# all of it and sits at the start of the file, so a ranged HTTP request reads
# it without downloading the model. --kv-probe uses this to fill each tier's
# MODEL_N_KV / MODEL_N_KV_SWA fields (see config/ai-coder-model.conf).

# Usage: gguf_read_header <url|path> <out_file> <bytes> — the first <bytes> of
# a local GGUF (read in place) or a remote one (Range request, proxy-aware).
gguf_read_header() {
    local _src="$1" _out="$2" _n="$3"
    if [ -f "$_src" ]; then
        head -c "$_n" "$_src" > "$_out"
    else
        # Via stdout: under MSYS_NO_PATHCONV a native curl.exe cant open /tmp paths.
        _asset_curl -sfL --max-time 60 -r "0-$(( _n - 1 ))" "$_src" > "$_out"
    fi
}

# Usage: gguf_kv_geometry <header_file> — parse the metadata and print
#   <arch> <layers> <K> <V> <K_swa> <V_swa> <window> <note>
# K/V are cache elements per token summed over the full-context layers; the
# _swa columns over the sliding-window layers (which cache at most <window>
# tokens). Element counts are quant-independent — the estimator applies the
# KV cache type. Prints "SHORT" when the header needs more bytes and
# "ERROR <reason>" when the file can't be sized.
#
# Streaming parse (no byte array — headers are MBs), stopping at the first
# tokenizer.* key once the architecture keys are in: converters write those
# first, and the vocab arrays after them are the bulk of the header.
# The SWA layout mirrors llama.cpp: a per-layer pattern array when the GGUF
# has one, otherwise the per-architecture pattern llama.cpp hardcodes
# (the last layer of each group of N is full-context). An unknown SWA
# architecture is counted as all full-context — an overestimate, never under.
gguf_kv_geometry() {
    # od errors (SIGPIPE) once awk stops reading early — expected.
    { od -An -v -tu1 -w4096 "$1" 2>/dev/null || true; } | LC_ALL=C awk '
    function rb() {
        while (bp > bn) {
            if ((getline ln) <= 0) { short = 1; return 0 }
            bn = split(ln, B, " "); bp = 1
        }
        return B[bp++] + 0
    }
    function skip(n,   avail) {
        while (n > 0 && !short) {
            avail = bn - bp + 1
            if (avail >= n) { bp += n; return }
            n -= avail; bp = bn + 1
            if ((getline ln) <= 0) { short = 1; return }
            bn = split(ln, B, " "); bp = 1
        }
    }
    function u(n,   v, m, i) { v = 0; m = 1; for (i = 0; i < n; i++) { v += rb() * m; m *= 256 } return v }
    function s(n,   v, lim) { v = u(n); lim = 2 ^ (8 * n - 1); return v >= lim ? v - 2 * lim : v }
    function str(   n, r, i) {
        n = u(8)
        if (n > 4096) { skip(n); return "" }
        r = ""; for (i = 0; i < n; i++) r = r sprintf("%c", rb())
        return r
    }
    # Fixed element sizes by GGUF value type; 0 = variable (string/array).
    function tsize(t) { return t <= 1 || t == 7 ? 1 : t <= 3 ? 2 : t <= 6 ? 4 : t >= 10 ? 8 : 0 }
    function val(t) {
        if (t == 0 || t == 7) return u(1)
        if (t == 1) return s(1)
        if (t == 2) return u(2)
        if (t == 3) return s(2)
        if (t == 4) return u(4)
        if (t == 5) return s(4)
        if (t == 8) return str()
        if (t == 10) return u(8)
        if (t == 11) return s(8)
        skip(tsize(t)); return ""   # floats: not needed
    }
    function arr(key,   et, n, i) {
        et = u(4); n = u(8)
        if (et == 8) { for (i = 0; i < n && !short; i++) skip(u(8)); return }
        if (et == 9 || tsize(et) == 0) { bad = "nested array in " key; return }
        # Per-layer arrays are small; anything bigger is data we never need.
        if (n > 4096 || et == 6 || et == 12) { skip(n * tsize(et)); return }
        AN[key] = n
        for (i = 0; i < n; i++) A[key, i] = val(et)
    }
    # Per-layer value of <key>: array element, scalar, or <dflt>.
    function per(key, i, dflt) {
        if (key in AN) return (i < AN[key]) ? A[key, i] : dflt
        if (key in V) return V[key]
        return dflt
    }
    function has(key) { return (key in V) || (key in AN) }
    BEGIN {
        bp = 1; bn = 0
        if (u(4) != 1179993927) { print "ERROR not a GGUF file"; exit }   # "GGUF"
        ver = u(4)
        if (ver < 2) { print "ERROR GGUF v" ver " is too old"; exit }
        u(8); nkv = u(8)
        for (k = 0; k < nkv; k++) {
            key = str(); t = u(4)
            if (short) break
            if (key ~ /^tokenizer\./ && ("general.architecture" in V) && \
                ((V["general.architecture"] ".block_count") in V)) break
            if (t == 9) arr(key); else V[key] = val(t)
            if (bad != "") { print "ERROR " bad; exit }
            if (short) break
        }
        if (short) { print "SHORT"; exit }
        arch = V["general.architecture"]; p = arch "."
        L = V[p "block_count"] + 0
        if (arch == "" || L <= 0) { print "ERROR no architecture/block_count"; exit }

        E = V[p "embedding_length"] + 0
        nh0 = per(p "attention.head_count", 0, 0) + 0
        kl = has(p "attention.key_length") ? V[p "attention.key_length"] : (nh0 ? E / nh0 : 0)
        vl = has(p "attention.value_length") ? V[p "attention.value_length"] : kl
        kls = has(p "attention.key_length_swa") ? V[p "attention.key_length_swa"] : kl
        vls = has(p "attention.value_length_swa") ? V[p "attention.value_length_swa"] : (has(p "attention.key_length_swa") ? kls : vl)
        lora = V[p "attention.kv_lora_rank"] + 0
        rope = V[p "rope.dimension_count"] + 0
        if (!lora && kl <= 0) { print "ERROR no head size"; exit }

        # Sliding window: an explicit window, or llama4 chunked attention.
        win = V[p "attention.sliding_window"] + 0
        pat = 0; note = ""
        # llama.cpp hardcodes llama4 chunked attention: 8192-token chunks
        # on 3 of every 4 layers.
        if (arch == "llama4") { win = 8192; pat = 4 }
        if (V[p "attention.chunk_size"] + 0 > 0) { win = V[p "attention.chunk_size"] + 0; pat = 4 }
        if (win > 0 && !((p "attention.sliding_window_pattern") in AN)) {
            if ((p "attention.sliding_window_pattern") in V) pat = V[p "attention.sliding_window_pattern"] + 0
            else if (!pat) {
                if (arch == "gemma2" || arch == "gpt-oss") pat = 2
                else if (arch == "gemma3") pat = 6
                else if (arch == "cohere2" || arch == "exaone4") pat = 4
                else { note = "unknown-swa-layout"; win = 0 }
            }
        }
        # Hybrid (linear-attention) models: only every Nth layer has a KV cache.
        fai = V[p "full_attention_interval"] + 0
        # MTP (next-token prediction) layers sit at the end and are full
        # attention; counted as cached, which errs high if llama.cpp skips them.
        nextn = V[p "nextn_predict_layers"] + 0
        # Gemma 3n/4: the last N layers reuse earlier layers KV.
        nkvl = L - (V[p "attention.shared_kv_layers"] + 0)

        KF = VF = KS = VS = 0
        for (i = 0; i < nkvl; i++) {
            if (fai > 0 && i < L - nextn && (i + 1) % fai != 0) continue
            nk = per(p "attention.head_count_kv", i, per(p "attention.head_count", i, 0)) + 0
            if (nk <= 0) continue
            swa = 0
            if (win > 0) {
                if ((p "attention.sliding_window_pattern") in AN) swa = per(p "attention.sliding_window_pattern", i, 0) + 0
                else if (pat > 0) swa = (i % pat < pat - 1)
            }
            if (lora) { k = lora + rope; v = 0 }   # MLA: compressed latent, V is a view of K
            else if (swa) { k = nk * kls; v = nk * vls }
            else { k = nk * kl; v = nk * vl }
            if (swa) { KS += k; VS += v } else { KF += k; VF += v }
        }
        if (KS == 0 && VS == 0) win = 0
        printf "%s %d %d %d %d %d %d %s\n", arch, L, KF, VF, KS, VS, win, (note == "" ? "-" : note)
    }
    '
}

# Usage: gguf_probe <url|path> — gguf_kv_geometry on as much of the header as
# it takes (1 MiB, growing to 32 MiB). Prints its result line; returns 1 on
# a fetch failure.
gguf_probe() {
    local _src="$1" _n=1048576 _tmp _res
    _tmp="$(mktemp "${TMPDIR:-/tmp}/ai-coder-gguf.XXXXXX")"
    while :; do
        if ! gguf_read_header "$_src" "$_tmp" "$_n"; then
            rm -f "$_tmp"; echo "ERROR fetch failed"; return 1
        fi
        _res=$(gguf_kv_geometry "$_tmp")
        if [ "$_res" != "SHORT" ] || [ "$_n" -ge 33554432 ]; then break; fi
        _n=$(( _n * 4 ))
    done
    rm -f "$_tmp"
    [ "$_res" = "SHORT" ] && _res="ERROR metadata larger than 32 MiB"
    echo "$_res"
}

# Usage: _kv_conf_set <conf> <tier> <field> <value> — set MODEL_<tier>_<field>
# in a family conf, in the ${VAR:-value} form: the line is replaced if
# present, else inserted after the tier's LAYERS line (WEIGHTS_GB when it has
# none; the KV line for KV_SWA). An empty value removes the line. The rewrite
# is syntax-checked before it replaces the conf.
_kv_conf_set() {
    local _conf="$1" _var="MODEL_${2}_${3}" _val="$4" _tmp
    local _after="MODEL_${2}_LAYERS"
    [ "$3" = "KV_SWA" ] && _after="MODEL_${2}_KV"
    grep -q "^${_after}=" "$_conf" || _after="MODEL_${2}_WEIGHTS_GB"
    _tmp="$(mktemp "${TMPDIR:-/tmp}/ai-coder-conf.XXXXXX")"
    awk -v var="$_var" -v val="$_val" -v after="$_after" '
        { lines[NR] = $0 }
        index($0, var "=") == 1 { found = 1 }
        END {
            line = var "=\"${" var ":-" val "}\""
            for (i = 1; i <= NR; i++) {
                if (index(lines[i], var "=") == 1) { if (val != "") print line; continue }
                print lines[i]
                if (!found && val != "" && index(lines[i], after "=") == 1) print line
            }
        }' "$_conf" > "$_tmp"
    if ! bash -n "$_tmp"; then
        rm -f "$_tmp"
        echo -e "${RED}✘ Rewrite of $(basename "$_conf") failed a syntax check — left unchanged${NC}"
        return 1
    fi
    cat "$_tmp" > "$_conf"
    rm -f "$_tmp"
}

# Usage: _kv_probe_family <conf> <write:true|false> — probe and print (and
# optionally write) one family's tiers. Run in a subshell: it sources the conf.
_kv_probe_family() {
    local _conf="$1" _write="$2"
    # Always the GGUF list, whichever engine is configured.
    ENGINE_BACKEND=llamacpp
    source "$_conf"
    ensure_ctx_config
    ensure_kv_config
    echo -e "\n${BOLD}${MODEL_FAMILY:-$(basename "$_conf" .conf)}${NC} ${DIM}($(basename "$_conf"); KV GB at ${MODEL_CTX_LEVEL:-64k} ctx, $(kv_type_label))${NC}"
    echo -e "${DIM}   # | DESC                                               | arch        | K/V elems/token | SWA K/V@window     | KV GB now → new${NC}"
    local i _count="${MODEL_COUNT:-0}" _file _url _src _res _desc
    local _arch _l _k _v _ks _vs _win _note _kv _swa _old _new _diff _changed=0
    for (( i=1; i<=_count; i++ )); do
        _file=$(_cand_field "$i" FILE); [ -n "$_file" ] || break
        _url=$(_cand_field "$i" URL)
        _desc=$(_cand_field "$i" DESC)
        _src="$MODEL_STORAGE_DIR/$_file"
        [ -f "$_src" ] || _src="$_url"
        _res=$(gguf_probe "$_src") || true
        if [ "${_res%% *}" = "ERROR" ]; then
            printf '  %2d | %-50.50s | %b\n' "$i" "$_desc" "${RED}${_res#ERROR }${NC}"
            continue
        fi
        read -r _arch _l _k _v _ks _vs _win _note <<< "$_res"
        _kv="$_k/$_v"; _swa=""
        [ "$_win" -gt 0 ] && _swa="$_ks/$_vs@$_win"
        _old=$(_estimate_kv_bytes "$i")
        printf -v "MODEL_${i}_KV" '%s' "$_kv"
        printf -v "MODEL_${i}_KV_SWA" '%s' "$_swa"
        _new=$(_estimate_kv_bytes "$i")
        _diff=$(awk -v o="$_old" -v n="$_new" 'BEGIN{g=1073741824; printf "%5.1f → %5.1f", o/g, n/g; if (n > 0 && (o/n > 1.02 || o/n < 0.98)) printf "  (was %+d%%)", (o-n)*100/n}')
        printf '  %2d | %-50.50s | %-11s | %-15s | %-18s | %s\n' "$i" "$_desc" "$_arch" "$_kv" "${_swa:--}" "$_diff"
        [ "$_note" = "-" ] || echo -e "       ${YELLOW}⚠ ${_note}: SWA layers counted as full-context (overestimate)${NC}"
        if $_write; then
            _kv_conf_set "$_conf" "$i" KV "$_kv" && _kv_conf_set "$_conf" "$i" KV_SWA "$_swa" || return 1
            _changed=1
        fi
    done
    [ "$_changed" -eq 1 ] && echo -e "  ${GREEN}✔ Wrote MODEL_N_KV/MODEL_N_KV_SWA to $(basename "$_conf")${NC}"
    return 0
}

# Read each tier's KV cache geometry from its GGUF header (local file if
# downloaded, else a ranged HTTP request — no model download) and compare
# the resulting KV estimate with the one the conf gives today. --write
# records the geometry in the conf as MODEL_N_KV / MODEL_N_KV_SWA.
# Usage: cmd_kv_probe [family-key|all] [--write]
# Without a key, uses the saved family_pref (user/state.json).
cmd_kv_probe() {
    local _target="" _write=false _a
    for _a in "$@"; do
        case "$_a" in
            --write) _write=true ;;
            *)       _target="$_a" ;;
        esac
    done
    [ -n "$_target" ] || _target=$(read_pref "$STATE_FILE" family_pref "")
    if [ -z "$_target" ]; then
        echo -e "${RED}No model family selected yet. Pass a family key (or all):${NC}"
        echo -e "${DIM}  $(basename "$0") --kv-probe <family-key|all> [--write]${NC}"
        return 1
    fi
    local _confs=() _conf _rc=0
    if [ "$_target" = "all" ]; then
        _confs=("$FAMILIES_DIR"/*.conf)
    elif [ -f "$FAMILIES_DIR/${_target}.conf" ]; then
        _confs=("$FAMILIES_DIR/${_target}.conf")
    else
        echo -e "${RED}Error: Unknown model family '${_target}'. Available families:${NC}"
        for _conf in "$FAMILIES_DIR"/*.conf; do
            [ -f "$_conf" ] && echo -e "  ${DIM}- $(basename "$_conf" .conf)${NC}"
        done
        return 1
    fi
    for _conf in "${_confs[@]}"; do
        ( _kv_probe_family "$_conf" "$_write" ) || _rc=1
    done
    $_write || echo -e "\n${DIM}Dry run — add --write to record these in the family conf(s).${NC}"
    return $_rc
}

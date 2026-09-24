#!/bin/bash
# ==============================================================================
# AI-CODER-GGUF.SH | Per-tier KV cache geometry from model metadata
# ==============================================================================
# Sourced by ai-coder-core.sh after ai-coder-model.sh — not run standalone.
#
# KV cache size is fixed by a model's architecture (layers x KV heads x head
# dim, sliding-window layout, MLA), not by its weight quant, and a family's
# tiers usually mix several base models. For llama.cpp the GGUF metadata
# header records all of it and sits at the start of the file, so a ranged
# HTTP request reads it without downloading the model; for SGLang it is the
# Hugging Face repo's small config.json. --kv-probe uses these to fill each
# tier's MODEL_N_KV / MODEL_N_KV_SWA (and MODEL_SGL_N_*) fields — see
# config/ai-coder-model.conf.

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
#   <arch> <layers> <K> <V> <K_swa> <V_swa> <window> <note> <mtp_layers>
# K/V are cache elements per token summed over the full-context layers; the
# _swa columns over the sliding-window layers (which cache at most <window>
# tokens); <mtp_layers> is the built-in MTP draft-head layer count
# (nextn_predict_layers, 0 when absent). Element counts are quant-independent — the estimator applies the
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
        printf "%s %d %d %d %d %d %d %s %d\n", arch, L, KF, VF, KS, VS, win, (note == "" ? "-" : note), nextn
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

# Usage: gguf_mtp_layers <path> — the built-in MTP draft-head layer count of a
# local GGUF (llama.cpp's --spec-type draft-mtp needs > 0). Prints nothing and
# returns 1 when the header can't be read.
gguf_mtp_layers() {
    local _res _n
    _res=$(gguf_probe "$1") || return 1
    [ "${_res%% *}" = "ERROR" ] && return 1
    _n=$(echo "$_res" | awk '{ print $9 }')
    [ -n "$_n" ] || return 1
    echo "$_n"
}

# jq program for hf_kv_probe: a Hugging Face config.json →
#   <arch> <layers> <K> <V> <K_swa> <V_swa> <window> <max_ctx>
# in cache elements per token, laid out the way SGLang v0.5.20 sizes its KV
# pool (configs/model_config.py, model_executor/pool_configurator.py and
# utils/hf_transformers/config.py): only the architectures SGLang gives a
# separate sliding-window pool report _swa columns — any other model's
# sliding layers are cached at full length, so they count as full layers.
# Linear-attention (hybrid) layers hold fixed-size state, not per-token KV.
_HF_KV_JQ=$(cat <<'JQ'
# Mirrors SGLang v0.5.20's KV pool layout (configs/model_config.py,
# model_executor/pool_configurator.py, utils/hf_transformers/config.py).
((.architectures // [])[0] // "") as $arch
| (.text_config // .) as $t
| ($t.num_hidden_layers // 0) as $L
| ($t.num_attention_heads // 0) as $nh
# Gemma 4 names the sliding-layer geometry as the base fields and the full
# layers as global_*; SGLang swaps them.
| (($t.model_type // .model_type // "") | startswith("gemma4")) as $g4
| (if $g4 then ($t.num_global_key_value_heads // $t.num_key_value_heads) else ($t.num_key_value_heads // $nh) end) as $kvh
| (if $g4 then ($t.global_head_dim // $t.head_dim) else ($t.head_dim // (if $nh > 0 then (($t.hidden_size // 0) / $nh | floor) else 0 end)) end) as $hd
| ($t.v_head_dim // $hd) as $vhd
| ($t.swa_num_key_value_heads // (if $g4 then $t.num_key_value_heads else $kvh end)) as $skvh
| ($t.swa_head_dim // (if $g4 then $t.head_dim else $hd end)) as $shd
| ($t.swa_v_head_dim // $shd) as $svhd
# Architectures SGLang gives a separate sliding-window pool; everything else
# caches its sliding layers at full length.
| ($arch | IN("Gemma4ForCausalLM", "Gemma4ForConditionalGeneration",
    "Gemma4UnifiedForConditionalGeneration", "GptOssForCausalLM",
    "Llama4ForConditionalGeneration")) as $hswa
| ($t.layer_types
    // (if $arch == "Llama4ForConditionalGeneration" then
          [range($L) | if (. + 1) % 4 == 0 then "full_attention" else "sliding_attention" end]
        elif ($t.full_attention_interval // 0) > 0 then
          [range($L) | if (. + 1) % $t.full_attention_interval == 0 then "full_attention" else "linear_attention" end]
        else [range($L) | "full_attention"] end)) as $types
| ([$types[] | select(. == "full_attention" or (. == "sliding_attention" and ($hswa | not)))] | length) as $nf
| ([$types[] | select(. == "sliding_attention" and $hswa)] | length) as $ns
| if $L == 0 then "ERROR no num_hidden_layers in config.json"
  elif ($t.kv_lora_rank // 0) > 0 then
    "\($arch) \($L) \($nf * ($t.kv_lora_rank + ($t.qk_rope_head_dim // 0))) 0 0 0 0 -"
  elif $hd == 0 then "ERROR no head size in config.json"
  else
    "\($arch) \($L) \($nf * $kvh * $hd) \($nf * $kvh * $vhd) \($ns * $skvh * $shd) \($ns * $skvh * $svhd) \(if $ns > 0 then ($t.sliding_window // 0) else 0 end) \($t.max_position_embeddings // "-")"
  end
JQ
)

# Usage: hf_kv_probe <repo> <revision> [snapshot-dir] — _HF_KV_JQ's result
# line for a Hugging Face repo's config.json: the downloaded snapshot's when
# present, else fetched at <revision> (a few KB). Prints "ERROR <reason>"
# and returns 1 when it can't be read.
hf_kv_probe() {
    local _repo="$1" _rev="${2:-main}" _dir="${3:-}" _tmp _res=""
    _tmp="$(mktemp "${TMPDIR:-/tmp}/ai-coder-hfcfg.XXXXXX")"
    if [ -n "$_dir" ] && [ -f "$_dir/config.json" ]; then
        cat "$_dir/config.json" > "$_tmp"
    elif ! _asset_curl -sfL --max-time 30 "https://huggingface.co/${_repo}/resolve/${_rev}/config.json" > "$_tmp"; then
        rm -f "$_tmp"; echo "ERROR fetch failed"; return 1
    fi
    # Via stdin: under MSYS_NO_PATHCONV a native jq.exe can't open /tmp paths.
    _res=$("$JQ_CMD" -r "$_HF_KV_JQ" < "$_tmp" 2>/dev/null | tr -d '\r') || _res=""
    rm -f "$_tmp"
    [ -n "$_res" ] || { echo "ERROR unreadable config.json"; return 1; }
    echo "$_res"
}

# Usage: _kv_conf_set <conf> <tier> <field> <value> — set MODEL_<tier>_<field>
# (<tier> is N, or SGL_N for the SGLang list) in a family conf, in the
# ${VAR:-value} form: the line is replaced if present, else inserted after
# the first of the tier's lines listed for <field> below that exists (so KV
# lands after LAYERS or WEIGHTS_GB, and KV_SWA / MAX_CTX follow it). An
# empty value removes the line. The rewrite is syntax-checked before it
# replaces the conf.
_kv_conf_set() {
    local _conf="$1" _var="MODEL_${2}_${3}" _val="$4" _tmp _after="" _f
    local _order="LAYERS WEIGHTS_GB"
    case "$3" in
        KV_SWA)  _order="KV $_order" ;;
        MAX_CTX) _order="KV_SWA KV $_order" ;;
    esac
    for _f in $_order; do
        if grep -q "^MODEL_${2}_${_f}=" "$_conf"; then _after="MODEL_${2}_${_f}"; break; fi
    done
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

# Usage: _kv_probe_row <#> <desc> <arch> <kv> <swa> <old-bytes> <new-bytes>
# — one --kv-probe table row.
_kv_probe_row() {
    local _diff
    _diff=$(awk -v o="$6" -v n="$7" 'BEGIN{g=1073741824; printf "%5.1f → %5.1f", o/g, n/g; if (n > 0 && (o/n > 1.02 || o/n < 0.98)) printf "  (was %+d%%)", (o-n)*100/n}')
    printf '  %2s | %-50.50s | %-15.15s | %-15s | %-18s | %s\n' "$1" "$2" "$3" "$4" "${5:--}" "$_diff"
}

# Usage: _kv_probe_family <conf> <write:true|false> — probe and print (and
# optionally write) one family's tiers: the GGUF list from each file's
# header, then the SGLang list (if any) from each repo's config.json.
# Run in a subshell: it sources the conf and switches ENGINE_BACKEND.
_kv_probe_family() {
    local _conf="$1" _write="$2"
    local i _count _file _src _res _desc _repo _rev
    local _arch _l _k _v _ks _vs _win _extra _nextn _kv _swa _max _old _new _changed=0
    local _head="   # | DESC                                               | arch            | K/V elems/token | SWA K/V@window     | KV GB now → new"
    ENGINE_BACKEND=llamacpp
    source "$_conf"
    ensure_ctx_config
    ensure_kv_config
    echo -e "\n${BOLD}${MODEL_FAMILY:-$(basename "$_conf" .conf)}${NC} ${DIM}($(basename "$_conf"); KV GB at ${MODEL_CTX_LEVEL:-64k} ctx)${NC}"
    echo -e "${DIM}  llama.cpp GGUF tiers ($(kv_type_label)):${NC}"
    echo -e "${DIM}${_head}${NC}"
    _count="${MODEL_COUNT:-0}"
    for (( i=1; i<=_count; i++ )); do
        _file=$(_cand_field "$i" FILE); [ -n "$_file" ] || break
        _desc=$(_cand_field "$i" DESC)
        _src="$MODEL_STORAGE_DIR/$_file"
        [ -f "$_src" ] || _src=$(_cand_field "$i" URL)
        _res=$(gguf_probe "$_src") || true
        if [ "${_res%% *}" = "ERROR" ]; then
            printf '  %2d | %-50.50s | %b\n' "$i" "$_desc" "${RED}${_res#ERROR }${NC}"
            continue
        fi
        read -r _arch _l _k _v _ks _vs _win _extra _nextn <<< "$_res"
        _kv="$_k/$_v"; _swa=""
        [ "$_win" -gt 0 ] && _swa="$_ks/$_vs@$_win"
        _old=$(_estimate_kv_bytes "$i")
        printf -v "MODEL_${i}_KV" '%s' "$_kv"
        printf -v "MODEL_${i}_KV_SWA" '%s' "$_swa"
        _new=$(_estimate_kv_bytes "$i")
        _kv_probe_row "$i" "$_desc" "$_arch" "$_kv" "$_swa" "$_old" "$_new"
        [ "$_extra" = "-" ] || echo -e "       ${YELLOW}⚠ ${_extra}: SWA layers counted as full-context (overestimate)${NC}"
        if $_write; then
            _kv_conf_set "$_conf" "$i" KV "$_kv" && _kv_conf_set "$_conf" "$i" KV_SWA "$_swa" || return 1
            _changed=1
        fi
    done

    _count="${MODEL_SGL_COUNT:-0}"
    if [ "$_count" -gt 0 ] 2>/dev/null; then
        ENGINE_BACKEND=sglang
        ensure_kv_config
        echo -e "${DIM}  SGLang tiers (KV ${MODEL_KV_TYPE}; context capped at each model's maximum):${NC}"
        echo -e "${DIM}${_head}${NC}"
        for (( i=1; i<=_count; i++ )); do
            _repo=$(_cand_field "$i" URL); [ -n "$_repo" ] || break
            _rev=$(_cand_field "$i" REVISION)
            _desc=$(_cand_field "$i" DESC)
            _res=$(hf_kv_probe "$_repo" "${_rev:-main}" "$MODEL_STORAGE_DIR/$(_cand_field "$i" FILE)") || true
            if [ "${_res%% *}" = "ERROR" ]; then
                printf '  %2d | %-50.50s | %b\n' "$i" "$_desc" "${RED}${_res#ERROR }${NC}"
                continue
            fi
            read -r _arch _l _k _v _ks _vs _win _max <<< "$_res"
            _kv="$_k/$_v"; _swa=""
            [ "$_ks" -gt 0 ] && _swa="$_ks/$_vs@$_win"
            case "$_max" in ''|*[!0-9]*) _max="" ;; esac
            _old=$(_estimate_kv_bytes "$i")
            printf -v "MODEL_SGL_${i}_KV" '%s' "$_kv"
            printf -v "MODEL_SGL_${i}_KV_SWA" '%s' "$_swa"
            printf -v "MODEL_SGL_${i}_MAX_CTX" '%s' "$_max"
            _new=$(_estimate_kv_bytes "$i")
            _kv_probe_row "$i" "$_desc" "$_arch" "$_kv" "$_swa" "$_old" "$_new"
            if $_write; then
                _kv_conf_set "$_conf" "SGL_$i" KV "$_kv" && _kv_conf_set "$_conf" "SGL_$i" KV_SWA "$_swa" \
                    && _kv_conf_set "$_conf" "SGL_$i" MAX_CTX "$_max" || return 1
                _changed=1
            fi
        done
    fi
    [ "$_changed" -eq 1 ] && echo -e "  ${GREEN}✔ Wrote KV geometry to $(basename "$_conf")${NC}"
    return 0
}

# Read each tier's KV cache geometry — from its GGUF header for llama.cpp
# (local file if downloaded, else a ranged HTTP request — no model download),
# from its repo's config.json for SGLang — and compare the resulting KV
# estimate with the one the conf gives today. --write records the geometry
# in the conf as MODEL_N_KV / MODEL_N_KV_SWA and MODEL_SGL_N_KV /
# MODEL_SGL_N_KV_SWA / MODEL_SGL_N_MAX_CTX.
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

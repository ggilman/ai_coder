# ==============================================================================
# SGLang patch: gemma4-unified-lm-head
# ==============================================================================
# Runs inside the SGLang engine container (bash) right before launch_server,
# for candidates that set MODEL_SGL_N_PATCH="gemma4-unified-lm-head".
#
# SGLang v0.5.20: Gemma4UnifiedForConditionalGeneration (the encoder-free
# Gemma-4 12B architecture) skips its parent's __init__, which is where
# lm_head_is_tied is set, so the first forward pass (CUDA-graph capture)
# dies with "object has no attribute 'lm_head_is_tied'". Re-add the
# assignment ahead of the tied-embedding check it mirrors. A no-op once
# upstream sets the attribute itself; warns (and lets the launch fail
# visibly) if the anchor line has moved.
_f=/sgl-workspace/sglang/python/sglang/srt/models/gemma4_unified.py
if [ -f "$_f" ] && ! grep -q 'self\.lm_head_is_tied' "$_f"; then
    sed -i 's/^\( *\)if self\.pp_group\.world_size == 1 and text_tie:$/\1self.lm_head_is_tied = self.pp_group.world_size == 1 and text_tie\n&/' "$_f"
    grep -q 'self\.lm_head_is_tied' "$_f" \
        || echo "ai-coder: patch gemma4-unified-lm-head found no anchor in $_f" >&2
fi
unset _f

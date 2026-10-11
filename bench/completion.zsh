# Tab completion for bench/suite.py (zsh). Add to ~/.zshrc, after compinit / oh-my-zsh:
#   source ~/github/dictation-app/bench/completion.zsh
# Candidates come from `suite.py __complete` (bench/completion.py), which reads the suites'
# own parsers, so new options complete without touching this file.

_dictation_bench_suite() {
  local out mode line
  local -a lines cands
  out=$("${(Q)words[1]}" __complete $((CURRENT - 2)) "${(@Q)words[2,-1]}" 2>/dev/null) || return 1
  lines=("${(@f)out}")
  mode=${lines[1]}
  for line in "${(@)lines[2,-1]}"; do
    cands+=("${${line%%$'\t'*}//:/\\:}:${line#*$'\t'}")
  done
  case $mode in
    values)       _describe -t values 'value' cands ;;
    values+files) _describe -t values 'value' cands; _files ;;
    files)        _files ;;
    dirs)         _files -/ ;;
    message:*)    _message -r "${mode#message:}" ;;
  esac
}

compdef _dictation_bench_suite suite.py

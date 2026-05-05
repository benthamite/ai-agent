# `ai-agent`: AI coding agent integration for Emacs

`ai-agent` collects the Emacs integration layer for AI coding command-line tools. It provides a shared session switcher, notifications, theme synchronization, terminal fixes, skill execution, and backend modules for Claude Code and Codex.

The package is for Emacs users who run AI coding agents inside terminal buffers and want one coherent interface instead of separate menus and keybindings per CLI. The core package handles backend registration and shared commands; `ai-agent-claude` adds Claude account switching, status polling, usage polling, branch navigation, batch TODO execution, and hook setup; `ai-agent-codex` adds Codex skill running, handoff, auditing, debugging, and modeline helpers.

## Installation

With `package-vc`:

```emacs-lisp
(use-package ai-agent
  :vc (:url "https://github.com/benthamite/ai-agent"))
```

With Elpaca:

```emacs-lisp
(use-package ai-agent
  :ensure (:host github :repo "benthamite/ai-agent"))
```

With straight.el:

```emacs-lisp
(use-package ai-agent
  :straight (:host github :repo "benthamite/ai-agent"))
```

Dependencies: Emacs 30 or later, `transient`, and `consult` for the core package. The Claude backend expects `claude-code`, `paths`, and `agent-log`; the Codex backend expects `codex`.

## Quick Start

```emacs-lisp
(use-package ai-agent
  :ensure (:host github :repo "benthamite/ai-agent")
  :after (claude-code codex)
  :demand t
  :config
  (require 'ai-agent-claude)
  (require 'ai-agent-codex))
```

Run `M-x ai-agent-menu` for the unified command menu, or bind it directly:

```emacs-lisp
(keymap-global-set "H-e" #'ai-agent-menu)
```

## Documentation

For a comprehensive description of all user options, commands, and functions, see the [manual](README.org).

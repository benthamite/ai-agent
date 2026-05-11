# `agent`: AI coding agent integration for Emacs

`agent` collects the Emacs integration layer for AI coding command-line tools. It provides a shared session switcher, notifications, theme synchronization, terminal fixes, skill execution, and backend modules for Claude Code and Codex.

The package is for Emacs users who run AI coding agent inside terminal buffers and want one coherent interface instead of separate menus and keybindings per CLI. The core package handles backend registration and shared commands; `agent-claude` adds Claude account switching, status polling, usage polling, branch navigation, batch TODO execution, and hook setup; `agent-codex` adds Codex account switching, skill running, handoff, auditing, debugging, and modeline helpers.

## Installation

With `package-vc`:

```emacs-lisp
(use-package agent
  :vc (:url "https://github.com/benthamite/agent"))
```

With Elpaca:

```emacs-lisp
(use-package agent
  :ensure (:host github :repo "benthamite/agent"))
```

With straight.el:

```emacs-lisp
(use-package agent
  :straight (:host github :repo "benthamite/agent"))
```

Dependencies: Emacs 30 or later, `transient`, and `consult` for the core package. The Claude backend expects `claude-code`, `paths`, and `agent-log`; the Codex backend expects `codex`.

## Quick Start

```emacs-lisp
(use-package agent
  :ensure (:host github :repo "benthamite/agent")
  :after (claude-code codex)
  :demand t
  :config
  (require 'agent-claude)
  (require 'agent-codex))
```

Run `M-x agent-menu` for the unified command menu, or bind it directly:

```emacs-lisp
(keymap-global-set "H-e" #'agent-menu)
```

## Documentation

For a comprehensive description of all user options, commands, and functions, see the [manual](README.org).

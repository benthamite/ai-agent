# `agents`: AI coding agent integration for Emacs

`agents` collects the Emacs integration layer for AI coding command-line tools. It provides a shared session switcher, notifications, theme synchronization, terminal fixes, skill execution, and backend modules for Claude Code and Codex.

The package is for Emacs users who run AI coding agents inside terminal buffers and want one coherent interface instead of separate menus and keybindings per CLI. The core package handles backend registration and shared commands; `agents-claude` adds Claude account switching, status polling, usage polling, branch navigation, batch TODO execution, and hook setup; `agents-codex` adds Codex account switching, skill running, handoff, auditing, debugging, and modeline helpers.

## Installation

With `package-vc`:

```emacs-lisp
(use-package agents
  :vc (:url "https://github.com/benthamite/agents"))
```

With Elpaca:

```emacs-lisp
(use-package agents
  :ensure (:host github :repo "benthamite/agents"))
```

With straight.el:

```emacs-lisp
(use-package agents
  :straight (:host github :repo "benthamite/agents"))
```

Dependencies: Emacs 30 or later, `transient`, and `consult` for the core package. The Claude backend expects `claude-code`, `paths`, and `agent-log`; the Codex backend expects `codex`.

## Quick Start

```emacs-lisp
(use-package agents
  :ensure (:host github :repo "benthamite/agents")
  :after (claude-code codex)
  :demand t
  :config
  (require 'agents-claude)
  (require 'agents-codex))
```

Run `M-x agents-menu` for the unified command menu, or bind it directly:

```emacs-lisp
(keymap-global-set "H-e" #'agents-menu)
```

## Documentation

For a comprehensive description of all user options, commands, and functions, see the [manual](README.org).

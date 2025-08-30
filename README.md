# planner.nvim

## What

A (WIP) productivity plugin for neovim that integrates a planner with google
calendar in order to sync your planner easily. 

> [!NOTE]
> Updates to the Planner always affect the Google Calendar but updates to the
> Google Calendar don't affect the planner. This follows a kind of "hub and
> spoke" philosophy where the one planner.nvim instance controls but a number of
> Google Calendar clients which can read the planner.

## Quick Setup

If you are on Neovim >= 0.12, then add this to your config:

```lua
vim.pack.add { "https://github.com/benraz123/planner.nvim" }
require "planner".setup"<path to credentials file for google calendar>"
```

For more on the process, see `:help pln-oauth` or [this article on the topic](https://developers.google.com/workspace/calendar/api/quickstart/python#set-up-environment)

## Usage

See `:help pln`

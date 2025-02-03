# autoread.nvim

A Neovim plugin that automatically reloads files when they are changed outside of the editor.

A pure-lua implementation that doesn't uses external binaries.

## Features

- Wakes neovim up to reload files in a given interval
- Optional notifications when files are reloaded
- Simple commands to enable/disable/toggle auto-reload
- Cursor position behavior after reload, like always scroll to the bottom

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "manuuurino/autoread.nvim",
    cmd = "Autoread",
    opts = {},
}
```

## Configuration

```lua
-- Default configuration
require("autoread").setup({
    -- Check interval in milliseconds
    interval = 500,
    -- Show notifications when files change
    notify_on_change = true,
    -- How to handle cursor position after reload: "preserve", "scroll_down", or "none"
    cursor_behavior = "preserve",
})
```

## Commands

- `:Autoread [interval]` - Toggle autoread on/off with optional **temporary** interval in milliseconds
  When providing an interval, it will update the interval if enabled or enable with that interval if disabled, rather than toggling off.
- `:AutoreadOn [interval]` - Enable autoread with optional **temporary** interval in milliseconds
- `:AutoreadOff` - Disable autoread
- `:AutoreadCursorBehavior <behavior>` - Set cursor behavior ("preserve", "scroll_down", or "none")

## API

```lua
local autoread = require("autoread")

-- Enable autoread with optional temporary interval
autoread.enable(1000) -- Check every 1000ms temporarily

-- Disable autoread
autoread.disable()

-- Toggle autoread with optional temporary interval
autoread.toggle(1000) -- Toggle with temporary 1000ms interval

-- Check if enabled
autoread.is_enabled()

-- Get configured interval
autoread.get_interval()

-- Set new default interval in configuration
autoread.set_interval(2000)

-- Updates the current timer to the desired interval temporarily
autoread.update_interval(500)

-- Set cursor behavior
autoread.set_cursor_behavior("preserve") -- "preserve", "scroll_down", or "none"
```

### Events

The plugin triggers the following User events that you can hook into:

- `AutoreadPreCheck` - Before checking files for changes
- `AutoreadPostCheck` - After checking files for changes
- `AutoreadPreReload` - Before reloading changed files
- `AutoreadPostReload` - After reloading changed files

Example of using events:

```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "AutoreadPostReload",
    callback = function(event)
        -- event.data contains the FileChangedShellPost event data
        print("File reloaded:", event.data.file)
    end,
})
```

## How it works

> NOTE: The plugin **does not** setup a file watcher, instead it lets
> neovim handle it, by just poking it to wake up.

Neovim uses the `checktime` command to detect file changes, see `:h checktime`.
This also gets triggered by itself, but only on an update, like a window refocus.

This plugin makes a somewhat wrapper for the `checktime` command, by calling it on every interval
with some additional features, like scroll to the bottom.

## Known issues

### Why might the cursor position jump to the top sometimes?

I discovered an edge case where the cursor position resets if the check (called with `checktime`)
happens exactly when a file is being cleared/written. When this happens, the buffer temporarily
becomes empty, causing the cursor to jump to the top,
also firing a `FileChangedShellPost` event (used in the script to determine a real file change).
And once the file has been fully written, it triggers another file change event.

With the `cursor_behavior = "preserve"` we keep a track of the cursor position
and apply it only then when the file is not empty.

## License

[MIT](./LICENSE)

local util = require "nvterm.termutil"
local a = vim.api
local nvterm = {}
local terminals = {}

local function get_last(list)
  if list then
    return not vim.tbl_isempty(list) and list[#list] or nil
  end
  return terminals[#terminals] or nil
end

local function get_type(type, list)
  list = list or terminals.list
  return vim.tbl_filter(function(t)
    return t.type == type
  end, list)
end

local function get_still_open()
  if not terminals.list then
    return {}
  end
  return #terminals.list > 0 and vim.tbl_filter(function(t)
    return t.open == true
  end, terminals.list) or {}
end

local function get_last_still_open()
  return get_last(get_still_open())
end

local function get_type_last(type)
  return get_last(get_type(type))
end

local function get_term(key, value)
  -- assumed to be unique, will only return 1 term regardless
  return vim.tbl_filter(function(t)
    return t[key] == value
  end, terminals.list)[1]
end

local create_term_window = function(type)
  local existing = terminals.list and #get_type(type, get_still_open()) > 0
  util.execute_type_cmd(type, terminals, existing)
  vim.wo.relativenumber = false
  vim.wo.number = false
  a.nvim_win_set_option(a.nvim_get_current_win(), "signcolumn", "no")
  return a.nvim_get_current_win()
end

local ensure_and_send = function(cmd, type)
  terminals = util.verify_terminals(terminals)
  local function select_term()
    if not type then
      return get_last_still_open() or nvterm.new "horizontal"
    else
      return get_type_last(type) or nvterm.new(type)
    end
  end
  local term = select_term()
  a.nvim_chan_send(term.job_id, cmd)
end

local call_and_restore = function(fn, opts)
  local current_win = a.nvim_get_current_win()
  local mode = a.nvim_get_mode().mode == "i" and "startinsert" or "stopinsert"

  fn(unpack(opts))
  a.nvim_set_current_win(current_win)

  vim.cmd(mode)
end

nvterm.is_term_open = function(type)
  return get_type_last(type) and true or false
end

nvterm.send = function(cmd, type)
  if not cmd then
    return
  end
  call_and_restore(ensure_and_send, { cmd, type })
end

nvterm.hide_term = function(term)
  terminals.list[term.id].open = false
  a.nvim_win_close(term.win, false)
end

nvterm.show_term = function(term)
  term.win = create_term_window(term.type)
  a.nvim_win_set_buf(term.win, term.buf)
  terminals.list[term.id].open = true
  if terminals.list[term.id].type ~= "nvwork" then
    vim.cmd "startinsert"
  end
end

nvterm.get_and_show = function(key, value)
  local term = get_term(key, value)
  nvterm.show_term(term)
end

nvterm.get_and_hide = function(key, value)
  local term = get_term(key, value)
  nvterm.hide_term(term)
end

nvterm.hide = function(type)
  local term = type and get_type_last(type) or get_last()
  nvterm.hide_term(term)
end

nvterm.show = function(type)
  terminals = util.verify_terminals(terminals)
  local term = type and get_type_last(type) or terminals.last
  nvterm.show_term(term)
end

nvterm.new = function(type, shell_override)
  local opts = terminals.type_opts[type]
  local win = create_term_window(type)
  local buf = a.nvim_create_buf(false, true)
  a.nvim_buf_set_option(buf, "filetype", "terminal")
  a.nvim_buf_set_option(buf, "buflisted", false)
  a.nvim_win_set_buf(win, buf)

  local job_id = vim.fn.termopen(opts.shell or terminals.shell or shell_override or vim.o.shell)

  local ok, pid = pcall(vim.fn.jobpid, job_id)
  if ok then
    local cwd = vim.fn.expand "~/"
    local cmd = pid .. " >> " .. cwd .. terminals.nvterm_info
    vim.fn.jobstart(cmd)
  end

  local id = #terminals.list + 1
  local term = { id = id, win = win, buf = buf, open = true, type = type, job_id = job_id }
  terminals.list[id] = term
  vim.cmd "startinsert"
  return term
end

nvterm.new_nvwork = function(type)
  local win = create_term_window(type)
  local buf = a.nvim_create_buf(false, true)
  a.nvim_buf_set_option(buf, "buflisted", false)
  a.nvim_win_set_buf(win, buf)

  vim.cmd("e " .. vim.g.nvwork_selected_file)

  -- This line hides the current buffer from tabline in some way.
  vim.cmd(vim.bo.buflisted and "set nobl" or "hide")

  local id = #terminals.list + 1
  local term = { id = id, win = win, buf = buf, open = true, type = type }
  terminals.list[id] = term
  return term
end

nvterm.toggle = function(type)
  terminals = util.verify_terminals(terminals)
  local term = get_type_last(type)

  if not term then
    if type == "nvwork" then
      term = nvterm.new_nvwork(type)
    else
      term = nvterm.new(type)
    end
  elseif term.open then
    nvterm.hide_term(term)
  else
    nvterm.show_term(term)

    if type == "nvwork" then
      if vim.fn.expand "%:p" ~= vim.g.nvwork_selected_file then
        vim.cmd("e " .. vim.g.nvwork_selected_file)
        vim.cmd(vim.bo.buflisted and "set nobl" or "hide")
      end
    end
  end
end

nvterm.toggle_all_terms = function()
  terminals = util.verify_terminals(terminals)

  for _, term in ipairs(terminals.list) do
    if term.open then
      nvterm.hide_term(term)
    else
      nvterm.show_term(term)
    end
  end
end

nvterm.close_all_terms = function()
  for _, buf in ipairs(nvterm.list_active_terms "buf") do
    vim.cmd("bd! " .. tostring(buf))
  end
end

nvterm.kill_terminals = function()
  if #terminals.list <= 0 then
    return
  end

  local cmd = "!taskkill /F"
  local count = 0

  for _, term in ipairs(terminals.list) do
    local ok, pid = pcall(vim.fn.jobpid, term.job_id)
    if ok then
      cmd = cmd .. " /PID " .. pid
      count = count + 1
    end
  end

  if count > 0 then
    vim.cmd(cmd)
  end
end

nvterm.list_active_terms = function(property)
  local terms = get_still_open()
  if property then
    return vim.tbl_map(function(t)
      return t[property]
    end, terms)
  end
  return terms
end

nvterm.list_terms = function()
  return terminals.list
end

nvterm.init = function(term_config)
  terminals = term_config
end

return nvterm

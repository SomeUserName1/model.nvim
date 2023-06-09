local segment = require('llm.segment')
local util = require('llm.util')

local M = {}

local function get_segment(input, segment_mode, hl_group)
  if segment_mode == segment.mode.REPLACE then
    if input.selection ~= nil then
      -- clear selection
      util.buf.set_text(input.selection, {})
      local seg = segment.create_segment_at(
        input.selection.start.row,
        input.selection.start.col,
        hl_group,
        0
      )

      seg.data.original = input.lines

      return seg
    else
      -- clear buffer
      local seg = segment.create_segment_at(0, 0, hl_group, 0)

      vim.api.nvim_buf_set_lines(0, 0, -1, false, {})

      seg.data.original = input.lines

      return seg
    end
  elseif segment_mode == segment.mode.APPEND then
    if input.selection ~= nil then
      return segment.create_segment_at(
        input.selection.stop.row,
        input.selection.stop.col,
        hl_group,
        0
      )
    else
      return segment.create_segment_at(#input.lines, 0, hl_group, 0)
    end
  elseif segment_mode == segment.mode.BUFFER then
    -- Find or create a scratch buffer for this plugin
    local llm_bfnr = vim.fn.bufnr('llm-scratch', true)

    if llm_bfnr == -1 then
      llm_bfnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(llm_bfnr, 'llm-scratch')
    end

    vim.api.nvim_buf_set_option(llm_bfnr, 'buftype', 'nowrite')
    vim.api.nvim_buf_set_lines(llm_bfnr, -2, -1, false, input.lines)

    -- Open the existing buffer or create a new one
    vim.api.nvim_set_current_buf(llm_bfnr)

    -- Create a segment at the end of the buffer
    local line_count = vim.api.nvim_buf_line_count(llm_bfnr)

    return segment.create_segment_at(line_count, 0, hl_group, llm_bfnr)
  elseif segment_mode == segment.mode.INSERT then
    local pos = util.cursor.position()

    return segment.create_segment_at(pos.row, pos.col, hl_group, 0)
  else
    error('Unknown segment mode: ' .. segment_mode)
  end
end

local function get_input(want_visual_selection)
  if want_visual_selection then
    local selection = util.cursor.selection()
    local lines = util.buf.text(selection)

    return {
      selection = selection,
      position = util.cursor.position(),
      lines = lines
    }
  else
    return {
      position = util.cursor.position(),
      lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    }
  end
end

local function get_before_after(input)
  return {
    before = util.buf.text({
      start = {
        row = 0,
        col = 0
      },
      stop = input.selection ~= nil and input.selection.start or input.position
    }),
    after = util.buf.text({
      start = input.selection ~= nil and input.selection.stop or input.position,
      stop = {
        row = -1,
        col = -1
      },
    })
  }
end

---@class Context
---@field before string
---@field after string
---@field filename string
---@field args string

---@class RequestCompletionHandleParams
---@field input string[]
---@field segment Segment
---@field context Context

---@param segment_mode SegmentMode
---@param want_visual_selection boolean
---@param hl_group string
---@param args string
---@return RequestCompletionHandleParams
local function build_request_handle_params(segment_mode, want_visual_selection, hl_group, args)
  -- TODO is args actually useful here?

  local function seg_mode(mode, selection)
    if mode == segment.mode.INSERT_OR_REPLACE then
      if selection then
        return segment.mode.REPLACE
      else
        return segment.mode.INSERT
      end
    end

    return mode
  end

  local input = get_input(want_visual_selection)
  local seg = get_segment(input, seg_mode(segment_mode, want_visual_selection), hl_group)

  local before_after = get_before_after(input)

  return {
    input = input.lines,
    segment = seg,
    context = {
      filename = util.buf.filename(),
      before = before_after.before,
      after = before_after.after,
      args = args,
    }
  }
end

---@param input string | string[]
---@param prompt Prompt
---@param handlers StreamHandlers
---@param context table
---@return function cancel callback
local function start_prompt(input, prompt, handlers, context)
  -- TODO args to prompts is probably less useful than the prompt buffer / helper

  local function as_string(str_or_strs)
    if type(input) == 'string' then
      return str_or_strs
    else
      return table.concat(str_or_strs, '\n')
    end
  end

  local prompt_built = assert(prompt.builder(as_string(input), context), 'prompt builder produced nil')

  local function do_request(built_params)
    local params = vim.tbl_extend(
      'force',
      (prompt.params or {}),
      built_params
    )

    return prompt.provider.request_completion_stream(handlers, params)
  end

  if type(prompt_built) == 'function' then
    local cancel

    prompt_built(function(prompt_params)
      -- x are the built params here
      cancel = do_request(prompt_params)
    end)

    return function()
      cancel()
    end
  else
    return do_request(prompt_built)
  end
end

local function request_completion_input_segment(handle_params, prompt)
  local seg = handle_params.segment

  local cancel = start_prompt(handle_params.input, prompt, {
    on_partial = function(partial)
      seg.add(partial)
    end,

    on_finish = function(_, reason)
      if reason == 'stop' then
        seg.clear_hl()
      elseif reason == 'length' then
        seg.highlight('Error')
        util.eshow('Hit token limit')
      else
        seg.highlight('Error')
        util.eshow('Response ended because: ' .. reason)
      end
    end,

    on_error = function(data, label)
      util.eshow(data, 'stream error ' .. label)
    end
  }, handle_params.context)

  seg.data.cancel = cancel
end

---@param prompt Prompt
function M.request_completion_stream(prompt, args, want_visual_selection, default_hl_group)
  local prompt_mode = prompt.mode or segment.mode.APPEND

  if type(prompt_mode) == 'table' then -- prompt_mode is StreamHandlers
    -- TODO probably want to just remove streamhandlers prompt mode
    local stream_handlers = prompt_mode

    local handle_params = build_request_handle_params(
      segment.mode.APPEND, -- we don't use the segment here, append will create an empty segment at end of selection
      want_visual_selection,
      prompt.hl_group or default_hl_group,
      ''
    )

    start_prompt(
      handle_params.input,
      prompt,
      stream_handlers,
      handle_params.context
    )

    return
  end

  ---@cast prompt_mode SegmentMode
  local handle_params = build_request_handle_params(
    prompt_mode,
    want_visual_selection,
    prompt.hl_group or default_hl_group,
    args
  )

  request_completion_input_segment(handle_params, prompt)
end

function M.request_multi_completion_streams(prompts, default_hl_group)
  for i, prompt in ipairs(prompts) do
    local handle_params = build_request_handle_params(
      segment.mode.APPEND, -- multi-mode always append only
      want_visual_selection,
      prompt.hl_group or default_hl_group,
      ''
    )

    -- try to avoid ratelimits
    vim.defer_fn(function()
      request_completion_input_segment(handle_params, prompt)
    end, i * 200)
  end
end

return M

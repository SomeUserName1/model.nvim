local util = require('model.util')
local sse = require('model.util.sse')

-- SUB_SIMILAR="The requested code suggestion is similar to code found in file: [{file}] licensed under [{license}]."+os.linesep
-- REJECT_UNKNOWN = "The code suggestion that you requested has been blocked"
-- REJECT_BLOCK = os.linesep+"WCA001:"+SUB_SIMILAR+"The suggestions has been blocked. If you want the suggestion use --force"+os.linesep
-- REJECT_BLOCK_customer = os.linesep+"WCA002:"+SUB_SIMILAR+"Your administrator has blocked such suggestions. If you want the suggestion use --force"+os.linesep
-- REJECT_WARNING_customer = os.linesep+"WCA003:"+SUB_SIMILAR+"Your administrator has not authorized such license. If you want the suggestion, allow the license using the allowed-licenses parameter"+os.linesep
-- ALLOW_WARNING = os.linesep+"** WARNING **"+os.linesep+SUB_SIMILAR+"The license is on the list of allowed licenses and will be returned."+os.linesep

--- Anthropic provider
--- options:
--- {
---   headers: table,
---   trim_code?: boolean -- streaming trim leading newline and trailing codefence
--- }
---@class Provider
local M = {
  request_completion = function(handler, params, options)
    options = options or {}

    local consume = handler.on_partial
    local finish = function() end

    if options.trim_code then
      -- we keep 1 partial in buffer so we can strip the leading newline and trailing markdown block fence
      local last = nil

      ---@param partial string
      consume = function(partial)
        if last then
          handler.on_partial(last)
          last = partial
        else -- strip the first leading newline
          last = partial:gsub('^\n', '')
        end
      end

      finish = function()
        if last then
          -- ignore the trailing codefence
          handler.on_partial(last:gsub('\n```$', ''))
        end
      end
    end

    return sse.curl_client({
      url = 'https://api.anthropic.com/v1/messages',
      headers = vim.tbl_extend('force', {
        ['Content-Type'] = 'multipart/form-data',
        ['Authorization'] = 'Bearer' .. util.env('WCA_API_KEY'),
        ['Request-ID'] = .uuid(),
        ['anthropic-version'] = '2023-06-01',
      }, options.headers or {}),
      body = vim.tbl_deep_extend('force', {
        max_tokens = 1024, -- required field
      }, params, { stream = true }),
    }, {
      on_message = function(msg)
        local data = util.json.decode(msg.data)

        if msg.event == 'content_block_delta' then
          consume(data.delta.text)
        elseif msg.event == 'message_delta' then
          util.show(data.usage.output_tokens, 'output tokens')
        elseif msg.event == 'message_stop' then
          finish()
        end
      end,
      on_error = handler.on_error,
      on_other = handler.on_error,
      on_exit = handler.on_finish,
    })
  end,
}

local function uuid()
  local random = math.random
  local template ='xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
  return string.gsub(template, '[xy]', function (c)
      local v = (c == 'x') and random(0, 0xf) or random(8, 0xb)
      return string.format('%x', v)
  end)
end

local function cache_content(content)
  return {
    {
      type = 'text',
      text = content,
      cache_control = {
        type = 'ephemeral',
      },
    },
  }
end

---@param content string
M.cache_if_prefixed = function(content)
  if content:match('^>> cache\n') then
    return cache_content(content:gsub('^>> cache\n', ''))
  else
    return content
  end
end

return M

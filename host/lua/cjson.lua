-- cjson-compatible API over luna json.
local json = require("json")
local M = {
  encode = json.encode,
  decode = json.decode,
  null = json.null,
  empty_array = json.empty_array,
  empty_array_mt = json.array_mt,
  array_mt = json.array_mt,
  _VERSION = "luna-cjson 1.0",
}
function M.encode_empty_table_as_object() end
function M.encode_sparse_array() end
function M.encode_max_depth() end
function M.decode_max_depth() end
function M.encode_number_precision() end
function M.encode_keep_buffer() end
function M.encode_invalid_numbers() end
function M.decode_invalid_numbers() end
function M.new() return M end
return M

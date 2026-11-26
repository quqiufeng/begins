function b64d(s)
  local map = {}
  local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  for i = 1, 64 do map[chars:sub(i,i)] = i - 1 end
  s = s:gsub("[^%w%+/=]", "")
  local out = {}
  for grp in s:gmatch("[^=]+") do end
  local i = 1
  while i <= #s do
    local c1 = map[s:sub(i,i)]; if not c1 then break end
    local c2 = map[s:sub(i+1,i+1)] or 0
    local c3 = map[s:sub(i+2,i+2)]
    local c4 = map[s:sub(i+3,i+3)]
    out[#out+1] = string.char(c1 * 4 + math.floor(c2 / 16))
    if c3 then out[#out+1] = string.char((c2 % 16) * 16 + c3) end
    if c3 and c4 then out[#out+1] = string.char((c3 % 4) * 64 + c4) end
    i = i + 4
  end
  return table.concat(out)
end

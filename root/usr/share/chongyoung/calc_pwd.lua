#!/usr/bin/lua
--
-- calc_pwd.lua - 根据种子（seed）与日期（day）计算当天密码
-- 用法: calc_pwd.lua <seed> <day>
-- 参数:
--   seed - 密钥种子字符串
--   day  - 日期（1-31）
-- 输出:
--   成功时在 stdout 输出 16 字符密码并退出 0；失败时退出码非 0
--

local seed = arg[1]
local day = tonumber(arg[2])

if not seed or not day then
    print("")
    os.exit(1)
end

-- data1: 每日使用的秘钥字符串表（索引 1-31）
local data1 = {
    [1]='5084972163', [2]='9801567243', [3]='7286059143', [4]='1850394726', [5]='1462578093',
    [6]='5042936178', [7]='0145937682', [8]='0964238571', [9]='3497651802', [10]='9125780643',
    [11]='8634972150', [12]='5924673801', [13]='8274053169', [14]='5841792063', [15]='2469385701',
    [16]='8205349671', [17]='7429516038', [18]='3769458021', [19]='5862370914', [20]='8529364170',
    [21]='7936082154', [22]='5786241930', [23]='0728643951', [24]='9418360257', [25]='5093287146',
    [26]='5647830192', [27]='3986145207', [28]='0942587136', [29]='4357069128', [30]='0956723814',
    [31]='1502796384'
}

-- get_date_token(d): 根据日期 d（1-31）生成初始 token 数组
-- 返回：token 表（长度 256）或 nil（无效日期）
local function get_date_token(d)
    local word = data1[d]
    if not word then return nil end
    
    local token = {}
    for i=0, 255 do token[i+1] = i end
    
    local index = 0
    for i=0, 255 do
        local char_idx = (i % #word) + 1
        local char_val = tonumber(string.sub(word, char_idx, char_idx))
        
        local val_i = token[i+1]
        index = (index + val_i + char_val) % 256
        
        local temp = token[i+1]
        token[i+1] = token[index+1]
        token[index+1] = temp
    end
    return token
end

-- bit_xor(a, b): 纯 Lua 实现的按位异或，用作没有 bit 库时的回退
local function bit_xor(a, b)
    local p, res = 1, 0
    while a > 0 or b > 0 do
        local ra, rb = a % 2, b % 2
        if ra ~= rb then res = res + p end
        a, b, p = (a - ra) / 2, (b - rb) / 2, p * 2
    end
    return res
end

-- get_passwd(pwd, d): 用给定的 pwd（字符串）和日期 d 生成当天密码
-- 算法概要：基于 date_token 进行置换产生伪随机流，与 pwd 字节异或，取结果 MD5 的子串作为密码
-- 返回：字符串（16 个十六进制字符）或 nil（失败）
local function get_passwd(pwd, d)
    local date_token = get_date_token(d)
    if not date_token then return nil end
    
    local passwd_token = {}
    local index1 = 0
    local index2 = 0
    
    -- Try to load bit library
    local has_bit, bit = pcall(require, "bit")
    local xor_func = has_bit and bit.bxor or bit_xor

    for i=1, #pwd do
        index1 = (index1 + 1) % 256
        local token1_val = date_token[index1+1]
        
        index2 = (index2 + token1_val) % 256
        
        local temp = date_token[index1+1]
        date_token[index1+1] = date_token[index2+1]
        date_token[index2+1] = temp
        
        local new_token1_val = date_token[index1+1]
        local new_token2_val = date_token[index2+1]
        
        local index = (new_token1_val + new_token2_val) % 256
        local final_token_val = date_token[index+1]
        
        local char_code = string.byte(pwd, i)
        local xor_val = xor_func(final_token_val, char_code)
        
        table.insert(passwd_token, string.char(xor_val))
    end
    
    local raw_bytes = table.concat(passwd_token)
    
    -- 计算 MD5 摘要：优先使用 nixio.crypto.hash（如果可用），否则回退调用系统的 md5sum
    local md5_hex
    local has_nixio, nixio = pcall(require, "nixio")
    
    if has_nixio and nixio.crypto and nixio.crypto.hash then
        md5_hex = nixio.crypto.hash("md5", raw_bytes)
    else
        -- 回退：通过 printf 原始字节并调用 md5sum 获取摘要
        local cmd = "printf '"
        for i=1, #raw_bytes do
            cmd = cmd .. string.format("\\x%02x", string.byte(raw_bytes, i))
        end
        cmd = cmd .. "' | md5sum"
        local handle = io.popen(cmd)
        local result = handle:read("*a")
        handle:close()
        md5_hex = string.match(result, "^(%x+)")
    end
    
    if not md5_hex then return nil end
    return string.sub(md5_hex, 9, 24)
end

-- 主调用：计算并输出密码；失败时以非 0 退出
local result = get_passwd(seed, day)
if result then
    print(result)
else
    os.exit(1)
end

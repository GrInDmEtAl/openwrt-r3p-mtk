#!/usr/bin/env lua

--[[
 * A lua library to manipulate mtk's wifi driver. used in luci-app-mtk.
 *
 * Hua Shao <nossiac@163.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License version 2.1
 * as published by the Free Software Foundation
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
]]

local mtkwifi = {}
local _, nixio = pcall(require, "nixio")

function mtkwifi.debug(...)
    local ff = io.open("/tmp/mtkwifi.dbg.log", "a")
    local vars = {...}
    for _, v in pairs(vars) do
        ff:write(v.." ")
    end
    ff:write("\n")
    ff:close()
end

if not nixio then
    nixio.syslog = mtkwifi.debug
end

function string:split(sep)
    local sep, fields = sep or ":", {}
    local pattern = string.format("([^%s]+)", sep)
    self:gsub(pattern, function(c) fields[#fields+1] = c end)
    return fields
end

function mtkwifi.__trim(s)
  if s then return (s:gsub("^%s*(.-)%s*$", "%1")) end
end

function mtkwifi.__handleSpecialChars(s)
    s = s:gsub("\\", "\\\\")
    s = s:gsub("\"", "\\\"")
    s = mtkwifi.__trim(s)
    return s
end

-- if order function given, sort by it by passing the table and keys a, b,
-- otherwise just sort the keys
function mtkwifi.__spairs(t, order)
    -- collect the keys
    local keys = {}
    for k in pairs(t) do keys[#keys+1] = k end
        table.sort(keys, order)
        -- return the iterator function
        local i = 0
        return function()
            i = i + 1
            if keys[i] then
                return keys[i], t[keys[i]]
            end
    end
end

function mtkwifi.__lines(str)
    local t = {}
    local function helper(line) table.insert(t, line) return "" end
    helper((str:gsub("(.-)\r?\n", helper)))
    return t
end

function mtkwifi.__get_l1dat()
    if not pcall(require, "l1dat_parser") then
        return
    end

    local parser = require("l1dat_parser")
    local l1dat = parser.load_l1_profile(parser.L1_DAT_PATH)

    return l1dat, parser
end

function mtkwifi.sleep(s)
    local ntime = os.clock() + s
    repeat until os.clock() > ntime
end

function mtkwifi.deepcopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[mtkwifi.deepcopy(orig_key)] = mtkwifi.deepcopy(orig_value)
        end
        setmetatable(copy, mtkwifi.deepcopy(getmetatable(orig)))
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

function mtkwifi.read_pipe(pipe)
    local fp = io.popen(pipe)
    local txt =  fp:read("*a")
    fp:close()
    return txt
end

-- Associated Stations
dme = mtkwifi.read_pipe("dmesg -c > /dev/null && iwpriv ra0 show stainfo & iwpriv rai0 show stainfo & sleep 1") or "?"
MAC = mtkwifi.read_pipe("dmesg | grep -ioE -B 7 '([-0-9]{3}/){3}...' | grep -ioE '([a-z0-9]{2}:){5}..' 2>/dev/null") or "?"
MAC2 = mtkwifi.read_pipe("dmesg | grep -ioE -B 7 '([-0-9]{3}/){1}.../0' | grep -ioE '([a-z0-9]{2}:){5}..' 2>/dev/null") or "?"
RSSI = mtkwifi.read_pipe("dmesg | grep -ioE '([-0-9]{3}/){3}...' 2>/dev/null") or "?"
RSSI2 = mtkwifi.read_pipe("dmesg | grep -ioE '([-0-9]{3}/){1}.../0' | grep -ioE '([-0-9]{3}/){1}...' 2>/dev/null") or "?"
BW = mtkwifi.read_pipe("dmesg | grep -ioE '([0-9]{2,3}[a-z]{1}/).{3,4}' 2>/dev/null" ) or "?"
BW2 = mtkwifi.read_pipe("dmesg | grep -ioE -A 3 '([-0-9]{3}/){1}.../0' | grep -ioE '([0-9]{2,3}[a-z]{1})' 2>/dev/null" ) or "?"
rate = mtkwifi.read_pipe("dmesg | grep -i -B 1 '0%' | grep -ioE '([0-9]{1,4}/[0-9]{1,4})' 2>/dev/null" ) or "?"
rate2 = mtkwifi.read_pipe("dmesg | grep -i -B 1 '100%' | grep -ioE '(] [1-9]{1,4})' | grep -ioE '([1-9]{1,4})' 2>/dev/null" ) or "?"
	
function mtkwifi.load_profile(path, raw)
    local cfgs = {}
    local content

    if path then
    local fd = io.open(path, "r")
    if not fd then return end
        content = fd:read("*all")
        fd:close()
    elseif raw then
        content = raw
    else
        return
    end

    -- convert profile into lua table
    for _,line in ipairs(mtkwifi.__lines(content)) do
        line = mtkwifi.__trim(line)
        if string.byte(line) ~= string.byte("#") then
            local i = string.find(line, "=")
            if i then
                local k,v
                k = string.sub(line, 1, i-1)
                v = string.sub(line, i+1)
                if cfgs[mtkwifi.__trim(k)] then
                    mtkwifi.debug("warning", "skip repeated key"..line)
                end
                cfgs[mtkwifi.__trim(k)] = mtkwifi.__trim(v) or ""
            else
                mtkwifi.debug("warning", "skip line without '=' "..line)
            end
        else
            mtkwifi.debug("warning", "skip comment line "..line)
        end
    end
    return cfgs
end

function mtkwifi.__profile_bak_path(profile)
    local bak = "/tmp/mtk/wifi/"..string.match(profile, "([^/]+\.dat)")..".last"
    os.execute("mkdir -p /tmp/mtk/wifi")
    return bak
end

function mtkwifi.save_profile(cfgs, path)

    if not cfgs then
        mtkwifi.debug("configuration was empty, nothing saved")
        return
    end

    local fd = io.open(path, "w")
    table.sort(cfgs, function(a,b) return a<b end)
    if not fd then return end
    fd:write("# Generated by mtkwifi.lua\n")
    fd:write("Default\n")
    for k,v in mtkwifi.__spairs(cfgs, function(a,b) return string.upper(a) < string.upper(b) end) do
        fd:write(k.."="..v.."\n")
    end
    fd:close()

    if pcall(require, "mtknvram") then
        local nvram = require("mtknvram")
        local l1dat, l1 = mtkwifi.__get_l1dat()
        local zone = l1 and l1.l1_path_to_zone(path)

        if not l1dat then
            mtkwifi.debug("save_profile: no l1dat", path)
            nvram.nvram_save_profile(path)
        else
            if zone then
                mtkwifi.debug("save_profile:", path, zone)
                nvram.nvram_save_profile(path, zone)
            else
                mtkwifi.debug("save_profile:", path)
                nvram.nvram_save_profile(path)
            end
        end
    end
end

-- if path2 not give, we use path1's backup.
function mtkwifi.diff_profile(path1, path2)
    assert(path1)
    if not path2 then
        path2 = mtkwifi.__profile_bak_path(path1)
        if not mtkwifi.exists(path2) then
            return {}
        end
    end
    assert(path2)

    local diff = {}
    local cfg1 = mtkwifi.load_profile(path1) or {}
    local cfg2 = mtkwifi.load_profile(path2) or {}

    for k,v in pairs(cfg1) do
        if cfg2[k] ~= cfg1[k] then
            diff[k] = {cfg1[k] or "", cfg2[k] or ""}
        end
    end

    for k,v in pairs(cfg2) do
        if cfg2[k] ~= cfg1[k] then
            diff[k] = {cfg1[k] or "", cfg2[k] or ""}
        end
    end

    return diff
end


-- Mode 12 and 13 are only available for STAs.
local WirelessModeList = {
    [0] = "B/G mixed",
    [1] = "B only",
    [2] = "A only in 5G",
	[3] = "B/G mixed",
    [4] = "G only",
    -- [5] = "A/B/G/GN/AN mixed",
    [6] = "N in 2.4G only",
    [7] = "G/GN", -- i.e., no CCK mode
    [8] = "A/AN mixed 5G",
    [9] = "B/G/N mixed",
	[10] = "G/N mixed",
    [11] = "only N in 5G band",
    -- [12] = "B/G/GN/A/AN/AC mixed",
	[13] = "N only",
    [14] = "A/AN/AC mixed 5G",
    [15] = "AC/AN mixed", --but no A mode
    [16] = "AX/B/G/GN mode",
    [17] = "AX/AC/AN mixed",
}

local DevicePropertyMap = {
    -- 2.4G
    {device="MT7603", band={"0", "1", "4", "6", "7", "9"}},
    {device="MT7620", band={"0", "1", "4", "6", "7", "9"}},
    {device="MT7622", band={"0", "1", "4", "9"}},
    {device="MT7628", band={"0", "1", "4", "6", "7", "9"}},
    -- 5G
    {device="MT7610", band={"2", "8", "11", "14", "15"}},
    {device="MT7612", band={"2", "8", "11", "14", "15"}},
    {device="MT7662", band={"2", "8", "11", "14", "15"}},
    -- Mix
    {device="MT7615", band={"1", "2", "3", "8", "9", "10", "13", "14"}}
}

local AuthModeList = {
    "Disable",
    "OPEN",--OPENWEP
    "SHARED",--SHAREDWEP
    "WEPAUTO",
    "WPA2",
    "WPA2PSK",
    "WPAPSKWPA2PSK",
    "WPA1WPA2",
    "IEEE8021X",
}

local WpsEnableAuthModeList = {
    "Disable",
    "OPEN",--OPENWEP
    "WPA2PSK",
    "WPAPSKWPA2PSK",
}

local ApCliAuthModeList = {
    "Disable",
    "OPEN",
    "SHARED",
    "WPAPSK",
    "WPA2PSK",
    "WPAPSKWPA2PSK",
    -- "WPA",
    -- "WPA2",
    -- "WPAWPA2",
    -- "8021X",
}

local WPA_Enc_List = {
    "AES",
    "TKIP",
    "TKIPAES",
}


local WEP_Enc_List = {
    "WEP",
}

local dbdc_prefix = {
    {"ra",  "rax"},
    {"rai", "ray"},
    {"rae", "raz"},
}

local dbdc_apcli_prefix = {
    {"apcli",  "apclix"},
    {"apclii", "apcliy"},
    {"apclie", "apcliz"},
}

function mtkwifi.__cfg2list(str)
    -- delimeter == ";"
    local i = 1
    local list = {}
    for k in string.gmatch(str, "([^;]+)") do
        list[i] = k
        i = i + 1
    end
    return list
end

function mtkwifi.token_set(str, n, v)
    -- n start from 1
    -- delimeter == ";"
    if not str then return end
    local tmp = mtkwifi.__cfg2list(str)
    if type(v) ~= type("") and type(v) ~= type(0) then
        mtkwifi.debug("err", "invalid value type in token_set, "..type(v))
        return
    end
    if #tmp < tonumber(n) then
        for i=#tmp, tonumber(n) do
            if not tmp[i] then
                tmp[i] = v -- pad holes with v !
            end
        end
    else
        tmp[n] = v
    end
    return table.concat(tmp, ";")
end


function mtkwifi.token_get(str, n, v)
    -- n starts from 1
    -- v is the backup in case token n is nil
    if not str then return v end
    local tmp = mtkwifi.__cfg2list(str)
    return tmp[tonumber(n)] or v
end

function mtkwifi.search_dev_and_profile_orig()
    local dir = io.popen("ls /etc/wireless/")
    if not dir then return end
    local result = {}
    -- case 1: mt76xx.dat (best)
    -- case 2: mt76xx.n.dat (multiple card of same dev)
    -- case 3: mt76xx.n.nG.dat (case 2 plus dbdc and multi-profile, bloody hell....)
    for line in dir:lines() do
        -- mtkwifi.debug("debug", "scan "..line)
        local tmp = io.popen("find /etc/wireless/"..line.." -type f -name \"*.dat\"")
        for datfile in tmp:lines() do
            -- mtkwifi.debug("debug", "test "..datfile)

            repeat do
            -- for case 1
            local devname = string.match(datfile, "("..line..").dat")
            if devname then
                result[devname] = datfile
                -- mtkwifi.debug("debug", "yes "..devname.."="..datfile)
                break
            end
            -- for case 2
            local devname = string.match(datfile, "("..line.."%.%d)%.dat")
            if devname then
                result[devname] = datfile
                -- mtkwifi.debug("debug", "yes "..devname.."="..datfile)
                break
            end
            -- for case 3
            local devname = string.match(datfile, "("..line.."%.%d%.%dG)%.dat")
            if devname then
                result[devname] = datfile
                -- mtkwifi.debug("debug", "yes "..devname.."="..datfile)
                break
            end
            end until true
        end
    end

    for k,v in pairs(result) do
        mtkwifi.debug("debug", "search_dev_and_profile_orig: "..k.."="..v)
    end

    return result
end

function mtkwifi.search_dev_and_profile_l1()
    local l1dat = mtkwifi.__get_l1dat()

    if not l1dat then return end

    local result = {}
    local dbdc_2nd_if = ""

    for k, dev in ipairs(l1dat) do
        dbdc_2nd_if = mtkwifi.token_get(dev.main_ifname, 2, nil)
        if dbdc_2nd_if then
            result[dev["INDEX"].."."..dev["mainidx"]..".1"] = mtkwifi.token_get(dev.profile_path, 1, nil)
            result[dev["INDEX"].."."..dev["mainidx"]..".2"] = mtkwifi.token_get(dev.profile_path, 2, nil)
        else
            result[dev["INDEX"].."."..dev["mainidx"]] = dev.profile_path
        end
    end

    for k,v in pairs(result) do
        mtkwifi.debug("debug", "search_dev_and_profile_l1: "..k.."="..v)
    end

    return result
end

function mtkwifi.search_dev_and_profile()
    return mtkwifi.search_dev_and_profile_l1() or mtkwifi.search_dev_and_profile_orig()
end

function mtkwifi.__setup_vifs(cfgs, devname, mainidx, subidx)
    local l1dat, l1 = mtkwifi.__get_l1dat()
    local dridx = l1dat and l1.DEV_RINDEX

    local prefix
    local main_ifname
    local vifs = {}
    local dev_idx = ""


    prefix = l1dat and l1dat[dridx][devname].ext_ifname or dbdc_prefix[mainidx][subidx]

    dev_idx = string.match(devname, "(%w+)")

    vifs["__prefix"] = prefix
    if (cfgs.BssidNum == nil) then
        mtkwifi.debug("BssidNum configuration value not found.")
        mtkwifi.debug("debug","BssidNum configuration value not found.")
        return
    end

    for j=1,tonumber(cfgs.BssidNum) do
        vifs[j] = {}
        vifs[j].vifidx = j -- start from 1
        dev_idx = string.match(devname, "(%w+)")
        main_ifname = l1dat and l1dat[dridx][devname].main_ifname or dbdc_prefix[mainidx][subidx].."0"

        mtkwifi.debug("setup_vifs", prefix, dev_idx, mainidx, subidx)

        vifs[j].vifname = j == 1 and main_ifname or prefix..(j-1)
        if mtkwifi.exists("/sys/class/net/"..vifs[j].vifname) then
            local flags = tonumber(mtkwifi.read_pipe("cat /sys/class/net/"..vifs[j].vifname.."/flags 2>/dev/null")) or 0
            vifs[j].state = flags%2 == 1 and "up" or "down"
        end
        vifs[j].__ssid = cfgs["SSID"..j]
        vifs[j].__bssid = mtkwifi.read_pipe("iwconfig "..prefix..(j-1).." | grep Point | sed 's/.*Point: //' 2>/dev/null") or "?"
        if dbdc then
            vifs[j].__channel = mtkwifi.token_get(cfgs.Channel, j, 0)
            vifs[j].__wirelessmode = mtkwifi.token_get(cfgs.WirelessMode, j, 0)
        end

        vifs[j].__authmode = mtkwifi.token_get(cfgs.AuthMode, j, "OPEN")
        vifs[j].__encrypttype = mtkwifi.token_get(cfgs.EncrypType, j, "NONE")
        vifs[j].__hidessid = mtkwifi.token_get(cfgs.HideSSID, j, 0)
        vifs[j].__noforwarding = mtkwifi.token_get(cfgs.NoForwarding, j, 0)
        vifs[j].__wmmcapable = mtkwifi.token_get(cfgs.WmmCapable, j, 0)
        vifs[j].__txrate = mtkwifi.token_get(cfgs.TxRate, j, 0)
        vifs[j].__ieee8021x = mtkwifi.token_get(cfgs.IEEE8021X, j, 0)
        vifs[j].__preauth = mtkwifi.token_get(cfgs.PreAuth, j, 0)
        vifs[j].__rekeymethod = mtkwifi.token_get(cfgs.RekeyMethod, j, 0)
        vifs[j].__rekeyinterval = mtkwifi.token_get(cfgs.RekeyInterval, j, 0)
        vifs[j].__pmkcacheperiod = mtkwifi.token_get(cfgs.PMKCachePeriod, j, 0)
        vifs[j].__ht_extcha = mtkwifi.token_get(cfgs.HT_EXTCHA, j, 0)
        vifs[j].__radius_server = mtkwifi.token_get(cfgs.RADIUS_Server, j, 0)
        vifs[j].__radius_port = mtkwifi.token_get(cfgs.RADIUS_Port, j, 0)
        vifs[j].__wepkey_id = mtkwifi.token_get(cfgs.DefaultKeyID, j, 0)
        vifs[j].__wscconfmode = mtkwifi.token_get(cfgs.WscConfMode, j, 0)
        vifs[j].__wepkeys = {
            cfgs["Key"..j.."Str1"],
            cfgs["Key"..j.."Str2"],
            cfgs["Key"..j.."Str3"],
            cfgs["Key"..j.."Str4"],
        }
        vifs[j].__wpapsk = cfgs["WPAPSK"..j]

        -- VoW
        vifs[j].__atc_tp     = mtkwifi.token_get(cfgs.VOW_Rate_Ctrl_En,    j, 0)
        vifs[j].__atc_min_tp = mtkwifi.token_get(cfgs.VOW_Group_Min_Rate,  j, "")
        vifs[j].__atc_max_tp = mtkwifi.token_get(cfgs.VOW_Group_Max_Rate,  j, "")
        vifs[j].__atc_at     = mtkwifi.token_get(cfgs.VOW_Airtime_Ctrl_En, j, 0)
        vifs[j].__atc_min_at = mtkwifi.token_get(cfgs.VOW_Group_Min_Ratio, j, "")
        vifs[j].__atc_max_at = mtkwifi.token_get(cfgs.VOW_Group_Max_Ratio, j, "")

        -- TODO index by vifname
        vifs[vifs[j].vifname] = vifs[j]
    end

    return vifs
end

function mtkwifi.__setup_apcli(cfgs, devname, mainidx, subidx)
    local l1dat, l1 = mtkwifi.__get_l1dat()
    local dridx = l1dat and l1.DEV_RINDEX

    local apcli = {}
    local dev_idx = string.match(devname, "(%w+)")
    local apcli_prefix = l1dat and l1dat[dridx][devname].apcli_ifname or
                         dbdc_apcli_prefix[mainidx][subidx]

    local apcli_name = apcli_prefix.."0"

    if mtkwifi.exists("/sys/class/net/"..apcli_name) then
        apcli.vifname = apcli_name
         apcli.vifidx = "1"
        local iwapcli = mtkwifi.read_pipe("iwconfig "..apcli_name.." | grep ESSID 2>/dev/null")

        local _,_,ssid = string.find(iwapcli, "ESSID:\"(.*)\"")
        local flags = tonumber(mtkwifi.read_pipe("cat /sys/class/net/"..apcli_name.."/flags 2>/dev/null")) or 0
        apcli.state = flags%2 == 1 and "up" or "down"
        if not ssid or ssid == "" then
            apcli.status = "Disconnected"
        else
            apcli.ssid = ssid
            apcli.status = "Connected"
        end
        apcli.devname = apcli_name
        apcli.bssid = mtkwifi.read_pipe("iwconfig "..apcli_name.." | grep Point | sed 's/.*Point: //' 2>/dev/null") or "?"
		apcli.rate = mtkwifi.read_pipe("iwconfig "..apcli_name.." | grep Rate= | sed 's/.*Rate=//' 2>/dev/null") or "?"
        local flags = tonumber(mtkwifi.read_pipe("cat /sys/class/net/"..apcli_name.."/flags 2>/dev/null")) or 0
        apcli.ifstatus = flags%2 == 1 and "up" or ""
        return apcli
    else
        return
    end
end

function mtkwifi.get_all_devs()
    local devs = {}
    local i = 1 -- dev idx
    local profiles = mtkwifi.search_dev_and_profile()
    local wpa_support = 0
    local wapi_support = 0

    for devname,profile in pairs(profiles) do
        mtkwifi.debug("debug", "checking "..profile)

        local fd = io.open(profile,"r")
        if not fd then
            mtkwifi.debug("debug", "cannot find "..profile)
        else
            fd:close()
            mtkwifi.debug("debug", "load "..profile)
            mtkwifi.debug("loading profile"..profile)
            local cfgs = mtkwifi.load_profile(profile)
            if not cfgs then
                mtkwifi.debug("error loading profile"..profile)
                mtkwifi.debug("err", "error loading "..profile)
                return
            end
            devs[i] = {}
            devs[i].vifs = {}
            devs[i].apcli = {}
            devs[i].devname = devname
            devs[i].profile = profile
            local tmp = ""
            tmp = string.split(devname, ".")
            devs[i].maindev = tmp[1]
            devs[i].mainidx = tonumber(tmp[2]) or 1
            devs[i].subdev = devname
            devs[i].subidx = string.match(tmp[3] or "", "(%d+)")=="2" and 2 or 1
            devs[i].devband = tonumber(tmp[3])
            if devs[i].devband then
                devs[i].multiprofile = true
                devs[i].dbdc = true
            end
            devs[i].version = mtkwifi.read_pipe("cat /etc/wireless/"..devs[i].maindev.."/version 2>/dev/null") or "unknown"
            devs[i].ApCliEnable = cfgs.ApCliEnable
            devs[i].WirelessMode = cfgs.WirelessMode
            devs[i].WirelessModeList = {}
            for key, value in pairs(DevicePropertyMap) do
                local found = string.find(string.upper(devname), string.upper(value.device))
                if found then
                    for k=1,#value.band do
                        devs[i].WirelessModeList[tonumber(value.band[k])] = WirelessModeList[tonumber(value.band[k])]
                    end
                end
            end
            devs[i].WscConfMode = cfgs.WscConfMode
            devs[i].AuthModeList = AuthModeList
            devs[i].WpsEnableAuthModeList = WpsEnableAuthModeList

            if wpa_support == 1 then
                table.insert(devs[i].AuthModeList,"WPAPSK")
                table.insert(devs[i].AuthModeList,"WPA")
            end

            if wapi_support == 1 then
                table.insert(devs[i].AuthModeList,"WAIPSK")
                table.insert(devs[i].AuthModeList,"WAICERT")
            end
            devs[i].ApCliAuthModeList = ApCliAuthModeList
            devs[i].WPA_Enc_List = WPA_Enc_List
            devs[i].WEP_Enc_List = WEP_Enc_List
            devs[i].Channel = tonumber(cfgs.Channel)
            devs[i].DBDC_MODE = tonumber(cfgs.DBDC_MODE)

            if cfgs.MUTxRxEnable then
                if tonumber(cfgs.ETxBfEnCond)==1
                    and tonumber(cfgs.MUTxRxEnable)==0
                    and tonumber(cfgs.ITxBfEn)==0
                    then devs[i].__mimo = 0
                elseif tonumber(cfgs.ETxBfEnCond)==0
                    and tonumber(cfgs.MUTxRxEnable)==0
                    and tonumber(cfgs.ITxBfEn)==1
                    then devs[i].__mimo = 1
                elseif tonumber(cfgs.ETxBfEnCond)==1
                    and tonumber(cfgs.MUTxRxEnable)==0
                    and tonumber(cfgs.ITxBfEn)==1
                    then devs[i].__mimo = 2
                elseif tonumber(cfgs.ETxBfEnCond)==1
                    and tonumber(cfgs.MUTxRxEnable)>0
                    and tonumber(cfgs.ITxBfEn)==0
                    then devs[i].__mimo = 3
                elseif tonumber(cfgs.ETxBfEnCond)==1
                    and tonumber(cfgs.MUTxRxEnable)>0
                    and tonumber(cfgs.ITxBfEn)==1
                    then devs[i].__mimo = 4
                else devs[i].__mimo = 5
                end
            end

            if cfgs.HT_BW == "0" or not cfgs.HT_BW then
                devs[i].__bw = "20"
            elseif cfgs.HT_BW == "1" and cfgs.VHT_BW == "0" or not cfgs.VHT_BW then
                if cfgs.HT_BSSCoexistence == "0" or not cfgs.HT_BSSCoexistence then
                    devs[i].__bw = "40"
                else
                    devs[i].__bw = "60" -- 20/40 coexist
                end
            elseif cfgs.HT_BW == "1" and cfgs.VHT_BW == "1" then
                devs[i].__bw = "80"
            elseif cfgs.HT_BW == "1" and cfgs.VHT_BW == "2" then
                devs[i].__bw = "160"
            elseif cfgs.HT_BW == "1" and cfgs.VHT_BW == "3" then
                devs[i].__bw = "161"
            end

            devs[i].vifs = mtkwifi.__setup_vifs(cfgs, devname, devs[i].mainidx, devs[i].subidx)
            devs[i].apcli = mtkwifi.__setup_apcli(cfgs, devname, devs[i].mainidx, devs[i].subidx)

            -- Setup reverse indices by devname
            devs[devname] = devs[i]

            if devs[i].apcli then
                devs[i][devs[i].apcli.devname] = devs[i].apcli
            end

            i = i + 1
        end
    end
    return devs
end

function mtkwifi.exists(path)
    local fp = io.open(path, "rb")
    if fp then fp:close() end
    return fp ~= nil
end

function mtkwifi.parse_mac(str)
    local macs = {}
    local pat = "^[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]$"

    local function ismac(str)
        if str:match(pat) then return str end
    end

    if not str then return macs end
    local t = str:split("\n")
    for _,v in pairs(t) do
            local mac = ismac(mtkwifi.__trim(v))
            if mac then
                table.insert(macs, mac)
            end
    end

    return macs
    -- body
end


function mtkwifi.scan_ap(vifname)
    os.execute("ifconfig "..vifname.." down")
    os.execute("ifconfig "..vifname.." up")
    os.execute("iwpriv "..vifname.." set SiteSurvey=0")
    os.execute("sleep 4") -- depends on your env
    local scan_result = mtkwifi.read_pipe("iwpriv "..vifname.." get_site_survey 2>/dev/null")

    local aplist = {}
    local xx = {}
    for i, line in ipairs(mtkwifi.__lines(scan_result)) do
        if #line>40 and string.match(line, " BSSID ") then
            xx.Ch = {string.find(line, "Ch "),3}
            xx.SSID = {string.find(line, "SSID "),32}
            xx.BSSID = {string.find(line, "BSSID "),17}
            xx.Security = {string.find(line, "Security "),22}
            xx.Signal = {string.find(line, "Sig%a%al"),4}
            xx.Mode = {string.find(line, "W-Mode"),5}
            xx.ExtCh = {string.find(line, "ExtCH"),6}
            xx.NT = {string.find(line, "NT"),2}
        end

        local tmp = {}
        if #line>40 and not string.match(line, " BSSID ") then
            tmp = {}
            tmp.channel = mtkwifi.__trim(string.sub(line, xx.Ch[1], xx.Ch[1]+xx.Ch[2]))
            tmp.ssid = mtkwifi.__trim(string.sub(line, xx.SSID[1], xx.SSID[1]+xx.SSID[2]))
            tmp.bssid = string.upper(mtkwifi.__trim(string.sub(line, xx.BSSID[1], xx.BSSID[1]+xx.BSSID[2])))
            tmp.security = mtkwifi.__trim(string.sub(line, xx.Security[1], xx.Security[1]+xx.Security[2]))
            tmp.authmode = mtkwifi.__trim(string.split(tmp.security, "/")[1])
            tmp.encrypttype = mtkwifi.__trim(string.split(tmp.security, "/")[2] or "NONE")
            tmp.rssi = mtkwifi.__trim(string.sub(line, xx.Signal[1], xx.Signal[1]+xx.Signal[2]))
            tmp.extch = mtkwifi.__trim(string.sub(line, xx.ExtCh[1], xx.ExtCh[1]+xx.ExtCh[2]))
            tmp.mode = mtkwifi.__trim(string.sub(line, xx.Mode[1], xx.Mode[1]+xx.Mode[2]))
            tmp.nt = mtkwifi.__trim(string.sub(line, xx.NT[1], xx.NT[1]+xx.NT[2]))
            table.insert(aplist, tmp)
        end
    end

    return aplist
end

function mtkwifi.__any_wsc_enabled(wsc_conf_mode)
    if (wsc_conf_mode == "") then
        return 0;
    end
    if (wsc_conf_mode == "7") then
        return 1;
    end
    if (wsc_conf_mode == "4") then
        return 1;
    end
    if (wsc_conf_mode == "2") then
        return 1;
    end
    if (wsc_conf_mode == "1") then
        return 1;
    end
    return 0;
end

function mtkwifi.__restart_if_wps(devname, ifname, cfgs)
    local devs = mtkwifi.get_all_devs()
    local ssid_index = devs[devname]["vifs"][ifname].vifidx
    local wsc_conf_mode = ""

    wsc_conf_mode=mtkwifi.token_get(cfgs["WscConfMode"], ssid_index, "")

    os.execute("iwpriv "..ifname.." set WscConfMode=0")
    mtkwifi.debug("iwpriv "..ifname.." set WscConfMode=0")
    os.execute("route delete 239.255.255.250")
    mtkwifi.debug("route delete 239.255.255.250")
    if(mtkwifi.__any_wsc_enabled(wsc_conf_mode)) then
        os.execute("iwpriv "..ifname.." set WscConfMode=7")
        mtkwifi.debug("iwpriv "..ifname.." set WscConfMode=7")
        os.execute("route add -host 239.255.255.250 dev br0")
        mtkwifi.debug("route add -host 239.255.255.250 dev br0")
    end

    -- execute wps_action.lua file to send signal for current interface
    os.execute("lua wps_action.lua "..ifname)
    mtkwifi.debug("lua wps_action.lua "..ifname)
    return cfgs
end

function mtkwifi.restart_8021x(devname, devices)
    local l1dat, l1 = mtkwifi.__get_l1dat()
    local dridx = l1dat and l1.DEV_RINDEX

    local devs = devices or mtkwifi.get_all_devs()
    local dev = devs[devname]
    local main_ifname = l1dat and l1dat[dridx][devname].main_ifname or dbdc_prefix[mainidx][subidx].."0"
    local prefix = l1dat and l1dat[dridx][devname].ext_ifname or dbdc_prefix[mainidx][subidx]

    local ps_cmd = "ps | grep -v grep | grep rt2860apd | grep "..main_ifname.." | awk '{print $1}'"
    local pid_cmd = "cat /var/run/rt2860apd_"..devs[devname].vifs[1].vifname..".pid"
    local apd_pid = mtkwifi.read_pipe(pid_cmd) or mtkwifi.read_pipe(ps_cmd)
    if tonumber(apd_pid) then
        os.execute("kill "..apd_pid)
    end

    local cfgs = mtkwifi.load_profile(devs[devname].profile)
    local auth_mode = cfgs['AuthMode']
    local ieee8021x = cfgs['IEEE8021X']
    local pat_auth_mode = {"WPA$", "WPA;", "WPA2$", "WPA2;", "WPA1WPA2$", "WPA1WPA2;"}
    local pat_ieee8021x = {"1$", "1;"}
    local apd_en = false

    for _, pat in ipairs(pat_auth_mode) do
        if string.find(auth_mode, pat) then
            apd_en = true
        end
    end

    for _, pat in ipairs(pat_ieee8021x) do
        if string.find(ieee8021x, pat) then
            apd_en = true
        end
    end

    if not apd_en then
        return
    end

    os.execute("rt2860apd -i "..main_ifname.." -p "..prefix)
end

return mtkwifi

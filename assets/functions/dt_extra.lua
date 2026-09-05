DT_joker_order = {}
DT_hand_order = {}

local function DT_can_preview()
    return G.SETTINGS.preview_score ~= false and (G.STATE == G.STATES.SELECTING_HAND or G.STATE == G.STATES.DRAW_TO_HAND or G.STATE == G.STATES.PLAY_TAROT)
end

G.FUNCS.DT_toggle_skip_anim = function()
    G:save_settings()
end

G.FUNCS.DT_toggle_preview = function()
    G:save_settings()
    if G.hand and G.STATE == G.STATES.SELECTING_HAND then
        G.hand:parse_highlighted()
    end
end

local function DT_reset_preview()
    G.DT_PREVIEW = nil
    if G.GAME and G.GAME.current_round and G.GAME.current_round.current_hand then
        G.GAME.current_round.current_hand.chip_total = 0
    end
end

local function DT_apply_preview()
    DT_reset_preview()
    if not DT_can_preview() then return end
    if not G.hand or not G.hand.highlighted or #G.hand.highlighted < 1 then return end
    if not DV or not DV.SIM or not DV.SIM.run then return end
    for _, c in ipairs(G.hand.highlighted) do
        if c.facing == "back" then return end
    end
    local ok, sim = pcall(DV.SIM.run)
    if not ok or not sim then return end
    G.DT_PREVIEW = sim.score
    local chips = DV.SIM.running.exact.chips
    local mult = DV.SIM.running.exact.mult
    local text, disp_text = G.FUNCS.get_poker_hand_info(G.hand.highlighted)
    if text == "NULL" then return end
    local name = disp_text
    if sim.dollars.min ~= sim.dollars.max then
        name = disp_text .. " $" .. tostring(sim.dollars.min) .. "-" .. tostring(sim.dollars.max)
    elseif sim.dollars.exact and sim.dollars.exact ~= 0 then
        if sim.dollars.exact > 0 then
            name = disp_text .. " +$" .. tostring(sim.dollars.exact)
        else
            name = disp_text .. " -$" .. tostring(-sim.dollars.exact)
        end
    end
    update_hand_text({immediate = true, nopulse = true, delay = 0}, {
        handname = name,
        level = G.GAME.hands[text] and G.GAME.hands[text].level or "",
        chips = chips,
        mult = mult,
        chip_total = sim.score.exact
    })
    G.GAME.current_round.current_hand.chip_total = sim.score.exact
end

local function DT_queue_preview()
    G.E_MANAGER:add_event(Event({
        trigger = "immediate",
        func = function()
            DT_apply_preview()
            return true
        end
    }))
end

local orig_hl = CardArea.parse_highlighted
function CardArea:parse_highlighted()
    orig_hl(self)
    if self == G.hand then DT_queue_preview() end
end

local orig_use = Card.use_consumeable
function Card:use_consumeable(area, copier)
    orig_use(self, area, copier)
    DT_queue_preview()
end

local orig_ca_update = CardArea.update
function CardArea:update(dt)
    orig_ca_update(self, dt)
    if not DT_can_preview() or #self.cards == 0 then return end
    local prev
    if self.config.type == "joker" and self.cards[1] and self.cards[1].ability and self.cards[1].ability.set == "Joker" then
        prev = DT_joker_order
    elseif self.config.type == "hand" then
        prev = DT_hand_order
    else
        return
    end
    local changed = false
    if #self.cards ~= #prev then
        prev = {}
        changed = true
    end
    for i, c in ipairs(self.cards) do
        if c.sort_id ~= prev[i] then
            prev[i] = c.sort_id
            changed = true
        end
    end
    if changed then
        if self.config.type == "joker" then
            DT_joker_order = prev
        else
            DT_hand_order = prev
        end
        DT_queue_preview()
    end
end

local orig_eval = G.FUNCS.evaluate_play
G.FUNCS.evaluate_play = function(e)
    orig_eval(e)
    G.E_MANAGER:add_event(Event({
        trigger = "after",
        func = function()
            DT_reset_preview()
            return true
        end
    }))
end

local orig_discard = G.FUNCS.discard_cards_from_highlighted
G.FUNCS.discard_cards_from_highlighted = function(e, is_hook_blind)
    orig_discard(e, is_hook_blind)
    if not is_hook_blind then DT_reset_preview() end
end

local orig_total = G.FUNCS.hand_chip_total_UI_set
G.FUNCS.hand_chip_total_UI_set = function(e)
    local p = G.DT_PREVIEW
    if p and p.min and p.max and p.min ~= p.max and p.max >= 1 then
        local t = number_format(p.min) .. "-" .. number_format(p.max)
        if t ~= G.GAME.current_round.current_hand.chip_total_text then
            e.config.object.scale = 0.5
            G.GAME.current_round.current_hand.chip_total_text = t
            e.config.object:update_text()
        end
        return
    end
    orig_total(e)
end

local function DT_prof()
    return tostring(G.SETTINGS.profile or 1)
end

G.FUNCS.DT_after_save = function()
    local hist_dir = DT_prof() .. '/sl_hist'
    love.mod_filesystem.createDirectory(hist_dir)
    G.SETTINGS.sl_history = G.SETTINGS.sl_history or {}
    local sl_path = DT_prof() .. '/save_mod_sl.jkr'
    local data = love.mod_filesystem.read(sl_path)
    if not data or data == '' then return end
    local rel = hist_dir .. '/' .. tostring(os.time()) .. '_' .. tostring(#G.SETTINGS.sl_history + 1) .. '.jkr'
    love.mod_filesystem.write(rel, data)
    table.insert(G.SETTINGS.sl_history, 1, {time = os.date('%m-%d %H:%M:%S'), file = rel})
    while #G.SETTINGS.sl_history > 5 do
        local oldh = table.remove(G.SETTINGS.sl_history)
        if oldh and oldh.file then love.mod_filesystem.remove(oldh.file) end
    end
    G:save_settings()
end

G.FUNCS.DT_load_hist = function(e)
    local idx = e.config.ref_table and e.config.ref_table.idx
    local item = G.SETTINGS.sl_history and G.SETTINGS.sl_history[idx]
    if not item or not item.file then
        attention_text({text = '该槽位为空', scale = 0.42, hold = 1.5})
        return
    end
    local raw = get_compressed(item.file)
    if raw then
        local decoded = STR_UNPACK(raw)
        if decoded and decoded.VERSION then
            if G.FUNCS.exit_overlay_menu then G.FUNCS.exit_overlay_menu() end
            G.E_MANAGER:clear_queue()
            G:delete_run()
            G.SAVED_GAME = decoded
            G:start_run({savetext = G.SAVED_GAME})
            return
        end
    end
    attention_text({text = '存档损坏', scale = 0.42, hold = 1.5})
end

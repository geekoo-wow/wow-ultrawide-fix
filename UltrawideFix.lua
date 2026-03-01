local addonName, addon = ...

-- Default Settings
local defaults = {
    maxWidth = 2560,
    maxHeight = 1440,
    restrictWidth = false,
    restrictHeight = false,
}

-- Initialize SavedVariables
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("UI_SCALE_CHANGED")
frame:RegisterEvent("DISPLAY_SIZE_CHANGED")

local function InitializeSettings()
    if not UltrawideFixDB then
        UltrawideFixDB = {}
    end
    if not UltrawideFixDB.profiles then
        UltrawideFixDB.profiles = {}
    end
end

local function GetResolutionKey()
    local physicalWidth, physicalHeight = GetPhysicalScreenSize()
    return string.format("%dx%d", physicalWidth, physicalHeight)
end

local function GetCurrentProfile()
    local key = GetResolutionKey()
    if UltrawideFixDB.profiles and UltrawideFixDB.profiles[key] then
        local profile = UltrawideFixDB.profiles[key]
        local merged = {}
        for k, v in pairs(defaults) do
            if profile[k] ~= nil then
                merged[k] = profile[k]
            else
                merged[k] = v
            end
        end
        return merged
    end
    return defaults
end

local function SetCurrentProfileValue(settingKey, value)
    local key = GetResolutionKey()
    if not UltrawideFixDB.profiles then
        UltrawideFixDB.profiles = {}
    end
    if type(UltrawideFixDB.profiles[key]) ~= "table" then
        UltrawideFixDB.profiles[key] = {}
    end
    UltrawideFixDB.profiles[key][settingKey] = value
end

local isResizing = false

local function UpdateUIParent()
    if isResizing then return end
    isResizing = true

    local physicalWidth, physicalHeight = GetPhysicalScreenSize()

    -- Use logical screen size for setting UIParent dimensions
    local logicalWidth = GetScreenWidth()
    local logicalHeight = GetScreenHeight()

    -- Reset UIParent to default before applying restrictions
    UIParent:ClearAllPoints()
    UIParent:SetPoint("CENTER")
    -- In WoW 10.0+ UIParent is often bounded by logical screen size
    UIParent:SetSize(logicalWidth, logicalHeight)

    local profile = GetCurrentProfile()

    local targetLogicalWidth = logicalWidth
    local targetLogicalHeight = logicalHeight

    if profile.restrictWidth then
        -- Scale user's pixel max to logical max
        local maxLogicalWidth = logicalWidth * (profile.maxWidth / physicalWidth)
        targetLogicalWidth = math.min(logicalWidth, maxLogicalWidth)
    end
    if profile.restrictHeight then
        local maxLogicalHeight = logicalHeight * (profile.maxHeight / physicalHeight)
        targetLogicalHeight = math.min(logicalHeight, maxLogicalHeight)
    end
    
    UIParent:SetSize(targetLogicalWidth, targetLogicalHeight)

    isResizing = false
end

-- Live Preview Logic
local previewFrame = nil
local previewTimer = nil

local function ShowPreview()
    if not previewFrame then
        previewFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        previewFrame:SetFrameStrata("TOOLTIP")
        previewFrame:SetPoint("CENTER")
        previewFrame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 2,
        })
        previewFrame:SetBackdropColor(0, 1, 0, 0.2) -- Transparent Green interior
        previewFrame:SetBackdropBorderColor(0, 1, 0, 1) -- Solid Green border
    end

    local physicalWidth, physicalHeight = GetPhysicalScreenSize()
    local logicalWidth = GetScreenWidth()
    local logicalHeight = GetScreenHeight()
    
    local targetLogicalWidth = logicalWidth
    local targetLogicalHeight = logicalHeight

    local profile = GetCurrentProfile()

    if profile.restrictWidth then
        local maxLogicalWidth = logicalWidth * (profile.maxWidth / physicalWidth)
        targetLogicalWidth = math.min(logicalWidth, maxLogicalWidth)
    end
    if profile.restrictHeight then
        local maxLogicalHeight = logicalHeight * (profile.maxHeight / physicalHeight)
        targetLogicalHeight = math.min(logicalHeight, maxLogicalHeight)
    end

    previewFrame:SetSize(targetLogicalWidth, targetLogicalHeight)
    previewFrame:Show()

    if previewTimer then
         previewTimer:Cancel()
    end
    previewTimer = C_Timer.NewTimer(3, function()
        previewFrame:Hide()
    end)
end

function addon.BuildSettingsMenu()
    local category_name = "Ultrawide Fix"
    local category = Settings.RegisterVerticalLayoutCategory(category_name)
    Settings.RegisterAddOnCategory(category)
    local restrictWidthSetting = Settings.RegisterProxySetting(
        category,
        "UltrawideFix_RestrictWidth",
        "boolean",
        "Restrict Width",
        false,
        function() return GetCurrentProfile().restrictWidth end,
        function(value)
            SetCurrentProfileValue("restrictWidth", value)
            UpdateUIParent()
            ShowPreview()
        end
    )
    Settings.CreateCheckbox(category, restrictWidthSetting, "Enable restricting the maximum width of the UI.")

    local maxWidthSetting = Settings.RegisterProxySetting(
        category,
        "UltrawideFix_MaxWidth",
        "number",
        "Max Width (pixels)",
        2560,
        function() 
            local pw = GetPhysicalScreenSize()
            local val = GetCurrentProfile().maxWidth
            return math.floor(math.min(pw, val) + 0.5)
        end,
        function(value)
            local pw = GetPhysicalScreenSize()
            value = math.floor(math.min(pw, value) + 0.5)
            SetCurrentProfileValue("maxWidth", value)
            UpdateUIParent()
            ShowPreview()
        end
    )
    local physicalWidth, physicalHeight = GetPhysicalScreenSize()
    local widthOptions = Settings.CreateSliderOptions(800, math.max(800, physicalWidth), 10)
    if MinimalSliderWithSteppersMixin then
        widthOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
    end
    Settings.CreateSlider(category, maxWidthSetting, widthOptions, "Maximum allowed width in pixels.")

    local restrictHeightSetting = Settings.RegisterProxySetting(
        category,
        "UltrawideFix_RestrictHeight",
        "boolean",
        "Restrict Height",
        false,
        function() return GetCurrentProfile().restrictHeight end,
        function(value)
            SetCurrentProfileValue("restrictHeight", value)
            UpdateUIParent()
            ShowPreview()
        end
    )
    Settings.CreateCheckbox(category, restrictHeightSetting, "Enable restricting the maximum height of the UI.")

    local maxHeightSetting = Settings.RegisterProxySetting(
        category,
        "UltrawideFix_MaxHeight",
        "number",
        "Max Height (pixels)",
        1440,
        function() 
            local pw, ph = GetPhysicalScreenSize()
            local val = GetCurrentProfile().maxHeight
            return math.floor(math.min(ph, val) + 0.5)
        end,
        function(value)
            local pw, ph = GetPhysicalScreenSize()
            value = math.floor(math.min(ph, value) + 0.5)
            SetCurrentProfileValue("maxHeight", value)
            UpdateUIParent()
            ShowPreview()
        end
    )
    local heightOptions = Settings.CreateSliderOptions(600, math.max(600, physicalHeight), 10)
    if MinimalSliderWithSteppersMixin then
        heightOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
    end
    Settings.CreateSlider(category, maxHeightSetting, heightOptions, "Maximum allowed height in pixels.")

    addon.UpdateSettingsUI = function()
        -- The modern DF API handles automatic binding to ProxySettings getters.
    end
end

frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        InitializeSettings()
        if addon.BuildSettingsMenu then
            addon.BuildSettingsMenu()
        end
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" or event == "DISPLAY_SIZE_CHANGED" or event == "UI_SCALE_CHANGED" then
        UpdateUIParent()
        if addon.UpdateSettingsUI then
            addon.UpdateSettingsUI()
        end
    end
end)

addon.UpdateUIParent = UpdateUIParent

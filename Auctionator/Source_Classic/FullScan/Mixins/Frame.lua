AuctionatorFullScanFrameMixin = {}

local FULL_SCAN_EVENTS = {
  "AUCTION_ITEM_LIST_UPDATE",
  "AUCTION_HOUSE_CLOSED",
}

function AuctionatorFullScanFrameMixin:OnLoad()
  Auctionator.Debug.Message("AuctionatorFullScanFrameMixin:OnLoad")
  Auctionator.EventBus:RegisterSource(self, "AuctionatorFullScanFrameMixin")
  self.state = Auctionator.SavedState
end

function AuctionatorFullScanFrameMixin:ResetData()
  self.scanData = {}
  self.dbKeysMapping = {}
end

function AuctionatorFullScanFrameMixin:InitiateScan()
  if self:CanInitiate() then
    Auctionator.EventBus:Fire(self, Auctionator.FullScan.Events.ScanStart)

    self.state.TimeOfLastGetAllScan = time()

    self.inProgress = true

    self:RegisterForEvents()
    Auctionator.Utilities.Message(AUCTIONATOR_L_STARTING_FULL_SCAN)

    --Patch to prevent an error being generated by the classic AH code
    if not ITEM_QUALITY_COLORS[-1] then
      ITEM_QUALITY_COLORS[-1] = {r=0, b=0, g=0}
    end

    QueryAuctionItems("", nil, nil, 0, nil, nil, true, false, nil)
    -- 10% complete after making the replicate request
    Auctionator.EventBus:Fire(self, Auctionator.FullScan.Events.ScanProgress, 0.1)
  else
    Auctionator.Utilities.Message(self:NextScanMessage())
  end
end

function AuctionatorFullScanFrameMixin:CanInitiate()
  local _, canDoGetAll = CanSendAuctionQuery()
  return canDoGetAll
end

function AuctionatorFullScanFrameMixin:NextScanMessage()
  local timeSinceLastScan = time() - (self.state.TimeOfLastGetAllScan or 0)
  local minutesUntilNextScan = 15 - math.ceil(timeSinceLastScan / 60)
  local secondsUntilNextScan = (15 * 60 - timeSinceLastScan) % 60

  return AUCTIONATOR_L_NEXT_SCAN_MESSAGE:format(minutesUntilNextScan, secondsUntilNextScan)
end

function AuctionatorFullScanFrameMixin:RegisterForEvents()
  Auctionator.Debug.Message("AuctionatorFullScanFrameMixin:RegisterForEvents()")

  FrameUtil.RegisterFrameForEvents(self, FULL_SCAN_EVENTS)
end

function AuctionatorFullScanFrameMixin:UnregisterForEvents()
  Auctionator.Debug.Message("AuctionatorFullScanFrameMixin:UnregisterForEvents()")

  FrameUtil.UnregisterFrameForEvents(self, FULL_SCAN_EVENTS)
end

function AuctionatorFullScanFrameMixin:CacheScanData()
  -- 20% complete after server response
  Auctionator.EventBus:Fire(self, Auctionator.FullScan.Events.ScanProgress, 0.2)

  self:ResetData()
  self.waitingForData = GetNumAuctionItems("list")

  self:ProcessBatch(
    0,
    250,
    self.waitingForData
  )
end

function AuctionatorFullScanFrameMixin:ProcessBatch(startIndex, stepSize, limit)
  if startIndex >= limit then
    return
  end

  -- 20-100% complete when 0-100% through caching the scan
  Auctionator.EventBus:Fire(self,
    Auctionator.FullScan.Events.ScanProgress,
    0.2 + startIndex/limit*0.8
  )

  Auctionator.Debug.Message("AuctionatorFullScanFrameMixin:ProcessBatch (links)", startIndex, stepSize, limit)

  local i = startIndex
  while i < startIndex+stepSize and i < limit do
    local info = { GetAuctionItemInfo("list", i) }
    local link = GetAuctionItemLink("list", i)
    local itemID = info[17]

    if itemID == 0 then
      self.waitingForData = self.waitingForData - 1
    elseif not link then
      local item = Item:CreateFromItemID(itemID)
      item:ContinueOnItemLoad((function(index)
        return function()
          -- Don't do anything when the AH window has been closed
          if not self.inProgress then
            return
          end

          local link = GetAuctionItemLink("list", index)

          Auctionator.Utilities.DBKeyFromLink(link, function(dbKeys)
            self.waitingForData = self.waitingForData - 1

            table.insert(self.scanData, {
              auctionInfo = { GetAuctionItemInfo("list", index) },
              itemLink      = link,
            })
            table.insert(self.dbKeysMapping, dbKeys)

            if self.waitingForData == 0 then
              self:EndProcessing()
            end
          end)
        end
      end)(i))
    else
      Auctionator.Utilities.DBKeyFromLink(link, function(dbKeys)
        self.waitingForData = self.waitingForData - 1
        table.insert(self.scanData, {
          auctionInfo = info,
          itemLink      = link,
        })
        table.insert(self.dbKeysMapping, dbKeys)

        if self.waitingForData == 0 then
          self:EndProcessing()
        end
      end)
    end

    i = i + 1
  end

  if self.waitingForData == 0 and self.inProgress then
    self:EndProcessing()
  end

  C_Timer.After(0.01, function()
    self:ProcessBatch(startIndex + stepSize, stepSize, limit)
  end)
end

function AuctionatorFullScanFrameMixin:OnEvent(event, ...)
  if event == "AUCTION_ITEM_LIST_UPDATE" then
    Auctionator.Debug.Message(event)

    FrameUtil.UnregisterFrameForEvents(self, { "AUCTION_ITEM_LIST_UPDATE" })
    self:CacheScanData()
  elseif event =="AUCTION_HOUSE_CLOSED" then
    self:UnregisterForEvents()

    if self.inProgress then
      self.inProgress = false
      self:ResetData()

      Auctionator.Utilities.Message(
        AUCTIONATOR_L_FULL_SCAN_FAILED .. " " .. self:NextScanMessage()
      )
      Auctionator.EventBus:Fire(self, Auctionator.FullScan.Events.ScanFailed)
    end
  end
end

local function GetInfo(auctionInfo)
  local available = auctionInfo[3]
  local buyoutPrice = auctionInfo[10]
  local effectivePrice = buyoutPrice / available
    
  return math.ceil(effectivePrice), available
end


local function MergeInfo(scanData, dbKeysMapping)
  local allInfo = {}
  local index = 0

  for index = 1, #scanData do
    local effectivePrice, available = GetInfo(scanData[index].auctionInfo)

    -- available > 0 check just in case Blizzard returns 0 available it
    -- occasionally does on retail and breaking the effectivePrice from GetInfo
    if available > 0 and effectivePrice ~= 0 then
      for _, dbKey in ipairs(dbKeysMapping[index]) do
        if allInfo[dbKey] == nil then
          allInfo[dbKey] = {}
        end

        table.insert(allInfo[dbKey],
          { price = effectivePrice, available = available }
        )
      end
    end
  end

  return allInfo
end

function AuctionatorFullScanFrameMixin:EndProcessing()
  local rawFullScan = self.scanData

  local count = Auctionator.Database:ProcessScan(MergeInfo(self.scanData, self.dbKeysMapping))
  Auctionator.Utilities.Message(AUCTIONATOR_L_FINISHED_PROCESSING:format(count))

  self.inProgress = false
  self:ResetData()

  self:UnregisterForEvents()

  Auctionator.EventBus:Fire(self, Auctionator.FullScan.Events.ScanComplete, rawFullScan)
end

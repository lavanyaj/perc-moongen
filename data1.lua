local device	= require "device"
local ffi = require("ffi")
local dpdk	= require "dpdk"
local dpdkc	= require "dpdkc"
local log = require "log"
local memory	= require "memory"
local ntoh16, hton16 = ntoh16, hton16
local stats		= require "stats"
local pkt = require("packet")
local pipe		= require "pipe"

local fsd = require "examples.perc-moongen-single.flow-size-distribution"
local PercLink = require "examples.perc-moongen-single.perc_link"

local percg = require "proto.percg"
local percc1 = require "proto.percc1"
local eth = require "proto.ethernet"

local ipc = require "examples.perc-moongen-single.ipc"
local monitor = require "examples.perc-moongen-single.monitor"
local perc_constants = require "examples.perc-moongen-single.constants"

local CONTROL_PACKET_SIZE = perc_constants.CONTROL_PACKET_SIZE
local DATA_PACKET_SIZE	= perc_constants.DATA_PACKET_SIZE
local ACK_PACKET_SIZE = perc_constants.ACK_PACKET_SIZE

ffi.cdef [[
typedef struct foo { bool active; 
uint64_t flow, size, sent, acked; double acked_time, start_time;
uint8_t percgSrc, percgDst;
union mac_address ethSrc, ethDst;
int currentRate, nextRate; double changeTime;}
 txQueueInfo;
typedef struct bar {
uint64_t flow, recv, acked, size;
uint8_t percgSrc, percgDst;
union mac_address ethSrc, ethDst;}
 rxQueueInfo;
]]

dataMod = {}

function dataMod.rxlog(str)
   if perc_constants.LOG_RXDATA then
      print("data2.lua rx log: " .. str)
   end
end

function dataMod.txlog(str)
   if perc_constants.LOG_TXDATA then
      print("data2.lua tx log: " .. str)
   end
end

function dataMod.warn(str)
   if perc_constants.WARN_DATA then
      print("data2.lua warn: " .. str)
   end
end

function initializePercc1Packet(buf, percgSrc, ethSrc,
				percgDst, ethDst,
			        flowId)
   buf:getPercc1Packet():fill{
      pktLength = CONTROL_PACKET_SIZE,
      percgSource = percgSrc, -- TO CHANGE
      percgDestination = percgDst, -- TO CHANGE
      percgFlowId = flowId, -- TO CHANGE
      percgIsData = percg.PROTO_CONTROL,
      percc1IsForward = percc1.IS_FORWARD,
      percc1IsExit = percc1.IS_NOT_EXIT,
      percc1Hop = 0,
      percc1MaxHops = 0,
      ethSrc = ethSrc, -- TO CHANGE
      ethDst = ethDst, -- TO CHANGE
      ethType = eth.TYPE_PERCG}
end

function commonControlProcess(pkt)
   do
      local tmp = pkt.eth:getDst()
      pkt.eth.setDst(pkt.eth:getSrc())
      pkt.eth.setSrc(tmp)
   end

   do
      local tmp = pkt.percg:getDestination()
      pkt.percg:setDestination(pkt.percg:getSource())
      pkt.percg:setSource(tmp)
   end
   
   -- get maxHops, then smallest index, two rates
   local maxHops = pkt.percc1:getHop()
   if (pkt.percc1:getIsForward() ~= percc1.IS_FORWARD) then
      maxHops = pkt.percc1:getMaxHops()
   end
   local bnInfo = pkt.percc1:getBottleneckInfo(maxHops)
   local bnRate1, bnRate2 = bnInfo.bnRate1, bnInfo.bnRate2   
   local bnBitmap = bnInfo.bnBitmap
   assert(bnRate1 ~= nil)
   assert(bnRate2 ~= nil)
   assert(bnBitmap ~= nil)
   -- then set rate at each index
   -- and unsat/ sat at each index
   --pkt.percg:setRatesAndLabelGivenBottleneck(rate, hop, maxHops)	      
   for i=1,maxHops do		 
      pkt.percc1:setOldLabel(i, pkt.percc1:getNewLabel(i))
      pkt.percc1:setOldRate(i,  pkt.percc1:getNewRate(i))
      if bnBitmap[i] ~= 1 then
	 pkt.percc1:setNewLabel(i, percc1.LABEL_SAT)
	 pkt.percc1:setNewRate(i,  bnRate1)
	 -- controlMod.log("setting new rate of " .. i
	 -- 	  .. " to " .. bnRate1)
      else
	 pkt.percc1:setNewLabel(i, percc1.LABEL_UNSAT)
	 pkt.percc1:setNewRate(i, bnRate2)
	 -- controlMod.log("setting new rate of " .. i
	 -- 	  .. " to " .. bnRate2)
      end
   end -- for i=1,maxHops
   pkt.percc1:setMaxHops(maxHops) -- and hop is the same

   do 
      if (pkt.percc1:getIsForward() ~= percc1.IS_FORWARD) then
	 pkt.percc1:setIsForward(percc1.IS_FORWARD)
      else
	 pkt.percc1:setIsForward(percc1.IS_NOT_FORWARD)
      end
   end
   
   return bnRate1
end


function receiverControlProcess(pkt)
   commonControlProcess(pkt)
end

function senderControlProcess(pkt, queueInfo, dpdkNow)
   local newRate = commmonControlProcess(pkt)
   if (pkt.percc1:GetIsExit() == percc1.IS_EXIT) then
      pkt.eth.setType(eth.TYPE_DROP)
      return
   end

   if (queueInfo == nil) then
      pkt.percc1:SetIsExit(percc1.IS_EXIT)
      return
   end

   -- update rate info
   assert(newRate ~= nil)
   assert(queueInfo.currentRate ~= -1)
   if (newRate < queueInfo.currenRate) then
      queueInfo.nextRate = newRate
      queueInfo.changeTime = dpdkNow
   elseif (queueInfo.nextRate == -1) then
      queueInfo.nextRate = newRate
      queueInfo.changeTime = dpdkNow + 2 * perc_constants.rtts
   elseif (newRate <= queueInfo.nextRate) then
      queueInfo.nextRate = newRate
   else
      assert(newRate > queueInfo.nextRate)
      queueInfo.nextRate = newRate
      queueInfo.changeTime = dpdkNow + 2 * perc_constants.rtts
   end
   return
end

-- sends data packets and receives acks
function dataMod.txSlave(dev, cdfFilepath, numFlows,
			 percgSrc, ethSrc,
			 tableDst, readyInfo,
			 isSending, isReceiving)
   dpdk.sleepMillis(500)   
   local thisCore = dpdk.getCore()   

   if type(ethSrc) == "number" then
      local buf = ffi.new("char[20]")
      dpdkc.get_mac_addr(ethSrc, buf)
      local ethSrcStr = ffi.string(buf)      
      ethSrc = parseMacAddress(ethSrcStr)
   elseif istype(macAddrType, ethSrc) then
      ethSrc = ethSrc
   else
      assert(false)
   end

   log:print("Data slave running on "
		.. " dev " .. dev.id 
		.. " MAC addr " .. toString(ethSrc)
		.. ", core " .. thisCore
		.. ", isSending " .. isSending
		.. ", isReceiving " .. isReceiving
		.. "\n")

   if isSending == false then
      assert(cdfFilepath == nil)
      assert(numFlows == nil)
      assert(tableDst == nil)
   end

   if isSending then
      assert(cdfFilepath ~= nil)
      assert(numFlows ~= nil)
      assert(tableDst ~= nil)
   end

   if isSending or isReceiving then
      assert(dev ~= nil)
      assert(ethSrc ~= nil)
      assert(percgSrc ~= nil)
      assert(readyInfo ~= nil)
   end
   
   -- sender variables for generating new
   -- data and control packets
   local flowSizes = nil
   local ethDst = nil
   local percgDst = nil

   if isSending then
      local flowSizes = fsd.create()
      flowSizes:loadCDF(cdfFilepath)
      local avgFlowSize = flowSizes:avg()
      assert(avgFlowSize > 0)
      log:info("loaded flow sizes file with avg. flow size "
		  .. tostring(avgFlowSize/1500) .. " packets.\n")

      local percgDst, ethDst = next(tableDst)


      if type(ethDst) == "number" then
	 local buf = ffi.new("char[20]")
	 dpdkc.get_mac_addr(ethDst, buf)
	 local ethDstStr = ffi.string(buf)      
	 ethDst = parseMacAddress(ethDstStr)
      elseif istype(macAddrType, ethDst) then
	 ethDst = ethDst
      else
	 assert(false)
      end
   end

   ipc.waitTillReady(readyInfo)

   -- common variables
   -- for control packets processing
   local cMem = nil
   local cBufs = nil
   local cRxQueue = nil
   local link = nil

   -- link statistics
   local txCtr = nil
   local rxCtr = nil
   
   -- sending thread's variables
   local cNewMem = nil
   local cNewBufs = nil

   local mem = nil
   local txBufs = nil
   local freeQueues = nil
   local queueInfo = nil
   local ackRxQueue = nil
   local ackRxBufs = nil

   local lastAckTime = nil
   local lastPeriodicTime = nil
   local nextSendTime = nil
   local nextFlowId = nil
   local numStarted = nil
   local numFinished = nil

   -- receiving thread's variables
   local ackMem = nil
   local ackTxBufs = nil
   local rxQueueInfo = nil
   local dataRxQueue = nil
   local dataRxBufs = nil

   -- To receive and reply to control packets
   if isSending or isReceiving then
      cMem = memory.createMemPool()
      cBufs = memory.bufArray()   
      cRxQueue = dev:getRxQueue(perc_constants.CONTROL_RXQUEUE)
      -- CONTROL_TX_QUEUE   
      link = PercLink:new()
      -- link statistics, and all tx queues      
      txCtr = stats:newDevTxCounter(dev, "plain")
      txQueues = {}
      for q=1,perc_constants.MAX_QUEUES do
	 txQueues[q] = dev:getTxQueue(q)
      end
      rxCtr = stats:newDevRxCounter(rxQueue, "plain")
   end
   
   if isSending then
      -- To send new control packets and receive/ responde
      -- to existing control packets
      cNewMem = memory.createMemPool{
      	 ["func"]=function(buf)
	    buf:getPercgPacket():fill{
	       pktLength = CONTROL_PACKET_SIZE,
	       ethType = eth.TYPE_PERCG}
      end}
      cNewBufs = cNewMem:bufArray()
      -- NEW_CONTROL_TXQUEUE
   end

   if isReceiving then
      -- To send ACKs and receive data
      ackMem = memory.createMemPool{
	 ["func"]=function(buf) 
	    buf:getPercgPacket():fill{
	       pktLength = ACK_PACKET_SIZE,
	       ethType = eth.TYPE_ACK,
	       ethSrc = perc_constants.ACK_TXQUEUE}
	 end
      }
      ackTxBufs = ackMem:bufArray()
      rxQueueInfo =
	 ffi.new("rxQueueInfo[?]",
		 perc_constants.MAX_QUEUES+1, {}) -- indexing from 
      -- invariants
      for q=1,perc_constants.MAX_QUEUES do
	 rxQueueInfo[q].recv = 0ULL
	 rxQueueInfo[q].size = 0ULL
	 rxQueueInfo[q].acked = 0ULL
      end

      dataRxQueue = dev:getRxQueue(perc_constants.DATA_RXQUEUE)
      dataRxBufs = memory.bufArray()
      -- ACK_TXQUEUE
   end

   if isSending then
      -- To send data and receive ACKs
      mem = {}
      txBufs = {}
      freeQueues = {}
      for i=1, perc_constants.MAX_QUEUES do
	 if i ~= perc_constants.CONTROL_TXQUEUE
	    and i ~= perc_constants.NEW_CONTROL_TXQUEUE
	    and i ~= perc_constants.ACK_TXQUEUE
	 and i ~= perc_constants.DROP_QUEUE then 
	    table.insert(freeQueues, i)
	 end
      end
      
      for q = 1, perc_constants.MAX_QUEUES do
	 mem[q] = memory.createMemPool{
	    ["func"]=function(buf)
	       buf:getPercgPacket():fill{
		  pktLength = DATA_PACKET_SIZE,
		  ethType = eth.TYPE_PERC_DATA}
	 end}
	 txBufs[q] = mem[q]:bufArray()
      end
      
      queueInfo = ffi.new("txQueueInfo[?]", perc_constants.MAX_QUEUES+1) -- indexing from 1
      ackRxQueue = dev:getRxQueue(perc_constants.ACK_RXQUEUE)
      ackRxBufs = memory.bufArray()

      lastAckTime = dpdk.getTime()
      lastPeriodicTime = dpdk.getTime()
      nextSendTime =  dpdk.getTime() + 0.1
      nextFlowId = 1
      
      numStarted = 0
      numFinished = 0
   end

   -- a thread that's receiving runs forever
   -- a thread that's only sending stops as soon as all finish
   while dpdk.running() and
      ((isSending and numFinished < numFlows)
	 or isReceiving) do      
      local dpdkNow = dpdk.getTime()	 

      if isSending then
	 if dpdkNow > nextSendTime and nextFlowId <= numFlows then
	    -- (get start messages)
	    nextSendTime = dpdkNow	+ 0.01
	    numStarted = numStarted + 1
	    local size = math.ceil(flowSizes:value()/1500.0)
	    local flow = nextFlowId
	    local percgDst = 1
	    assert(next(freeQueues) ~= nil)
	    local q = table.remove(freeQueues)
	    assert(q ~= nil)
	    queueInfo[q].flow = flow
	    queueInfo[q].ethSrc = ethSrc
	    queueInfo[q].ethDst = ethDst
	    queueInfo[q].percgSrc = percgSrc
	    queueInfo[q].percgDst = percgDst -- actually device id only
	    queueInfo[q].size = size
	    queueInfo[q].sent = 0
	    queueInfo[q].acked = 0
	    queueInfo[q].active = true
	    queueInfo[q].acked_time = dpdkNow
	    queueInfo[q].start_time = dpdkNow
	    queueInfo[q].currentRate = dev:getTxQueue(q):getTxRate()
	    queueInfo[q].nextRate = -1
	    queueInfo[q].changeTime = -1
	    log:info("flow " .. tostring(flow)
			.. " started (queue " .. tostring(q) .. ")")


	    -- send  a new control packet
	    cNewBufs:alloc(1)
	    initializePercc1Packet(cNewBufs[1], percgSrc, ethSrc,
				   percgDst, ethDst, flow)
	    txQueues[perc_constants.NEW_CONTROL_TXQUEUE]:send(cNewBufs)
	    nextFlowId = nextFlowId + 1
	 end -- ends do (get start messages)
      end

      do -- receive control packets, process and send back
	 local rx = cRxQueue:tryRecv(cBufs, 20)
	 for b = 1, rx do
	    local pkt = cBufs[b].getPercc1Packet()
	    pkt.percc1:doNtoh()
	    link:processPercc1Packet(pkt)
	    if pkt.percc1:IsForward() then receiverControlProcess(pkt)
	    else
	       assert(isSending)
	       if (isSending) then
		  local q = tonumber(pkt.payload.uint32[0])
		  local qi = queueInfo[q]
		  if qi.active == false or
		  tonumber(qi.flow) ~= pkt.percg:getFlowId() then
		     qi = nil
		  end
		  -- TODO: check it's passed by ref
		  senderProcess(pkt, qi, dpdkNow)
		  if qi ~= nil and qi.changeTime == dpdkNow then
		     txQueues[q].setRate(qi.nextRate)
		     qi.nextRate = -1
		     qi.currentRate = qi.nextRate
		     qi.changeTime = -1
		  end
		  link:processPercc1Packet(pkt)
	       end
	    end
	    pkt.percc1:doHton()
	 end
	 txQueues[perc_constants.CONTROL_TXQUEUE]:sendN(cBufs, rx)
      end

      if isSending then
	 do -- (send data packets)
	    for q=1,perc_constants.MAX_QUEUES do
	       assert(queueInfo[q].size >= queueInfo[q].sent)
	       if queueInfo[q].active
	       and queueInfo[q].sent < queueInfo[q].size then
		  local remaining = queueInfo[q].size - queueInfo[q].sent
		  if (remaining < txBufs[q].maxSize)
		  then
		     txBufs[q]:allocN(DATA_PACKET_SIZE, remaining)
		  else
		     txBufs[q]:allocN(DATA_PACKET_SIZE, txBufs[q].maxSize)
		  end
		  for _, buf in ipairs(txBufs[q]) do
		     local pkt = buf:getPercgPacket()
		     pkt.percg:setSource(queueInfo[q].percgSrc)
		     pkt.percg:setDestination(queueInfo[q].percgDst)
		     pkt.eth:setSrc(queueInfo[q].ethSrc)
		     pkt.eth:setDst(queueInfo[q].ethDst)		  
		     pkt.percg:setFlowId(queueInfo[q].flow) -- 32b -> 16b
		     pkt.payload.uint64[0] = queueInfo[q].flow
		     pkt.payload.uint64[1] = q
		     pkt.payload.uint64[4] = queueInfo[q].size
		     pkt.eth:setSrc(q)
		     pkt.eth:setType(eth.TYPE_PERC_DATA)
		     queueInfo[q].sent = queueInfo[q].sent + 1		  
		  end
		  txCtr:update()
		  txQueues[q]:send(txBufs[q])
	       end
	    end  -- ends for q=1,perc_constants.MAX_QUEUES
	 end  -- ends do (send data packets)
	 
	 do -- (receive acks)
	    local now = dpdk.getTime()
	    local rx = ackRxQueue:tryRecv(ackRxBufs, 20)
	    for b = 1 , rx do
	       local pkt = ackRxBufs[b]:getPercgPacket()
	       local flow = pkt.payload.uint64[0]
	       local q = pkt.payload.uint64[1]
	       local acked = pkt.payload.uint64[2]
	       if (queueInfo[q].active
		      and queueInfo[q].flow == flow
		   and pkt.payload.uint64[2] > queueInfo[q].acked) then    
		  queueInfo[q].acked = pkt.payload.uint64[2]
		  queueInfo[q].acked_time = now
		  assert(queueInfo[q].acked <= queueInfo[q].size)
		  if (queueInfo[q].acked == queueInfo[q].size) then
		     queueInfo[q].active = false
		     table.insert(freeQueues, q)
		     local fct = queueInfo[q].acked_time - queueInfo[q].start_time
		     log:info("flow " .. tostring(queueInfo[q].flow)
				 .. " ended (queue " .. tostring(q) .. ")"
				 .. " fct: " .. tostring(fct)
				 .. " size: " .. tostring(queueInfo[q].size)
				 .. " acked: " .. tostring(queueInfo[q].acked))
		     numFinished = numFinished + 1
		  end
	       end
	    end
	    ackRxBufs:freeAll()
	 end -- ends do (receive acks)
	 
	 -- timeout flows that haven't received acks in a while
	 if dpdkNow > lastAckTime + 1 then
	    lastAckTime = dpdkNow
	    for q=1,perc_constants.MAX_QUEUES do
	       if queueInfo[q].active and
		  (lastAckTime > tonumber(queueInfo[q].acked_time)
		   or queueInfo[q].size == queueInfo[q].acked) then
		     log:info("flow " .. tostring(queueInfo[q].flow)
				 .. " timed out (queue " .. q .. ")")
		     queueInfo[q].active = false
		     table.insert(freeQueues, q)
		     numFinished = numFinished + 1
	       end 
	    end -- ends for q=1,..
	 end -- ends do
      end


      if isReceiving then
	 do -- receive data packets and send ACKs
	    --dataMod.rxlog("receive data packets\n")
	    local ackNow = false
	    do
	       local rx = dataRxQueue:recv(dataRxBufs)
	       for b = 1, rx do
		  local buf = dataRxBufs[b]
		  local pkt = buf:getPercgPacket()
		  local flow = pkt.payload.uint64[0]
		  local q = pkt.payload.uint64[1]
		  local size = pkt.payload.uint64[4]
		  if rxQueueInfo[q].flow ~= flow then
		     rxQueueInfo[q].flow = flow 
		     rxQueueInfo[q].recv = 0ULL
		     rxQueueInfo[q].acked = 0ULL
		     rxQueueInfo[q].size = size
		     rxQueueInfo[q].ethSrc = pkt.eth.src
		     rxQueueInfo[q].ethDst = pkt.eth.dst
		     rxQueueInfo[q].percgSrc = pkt.percg:getSource()
		     rxQueueInfo[q].percgDst = pkt.percg:getDestination()
		  end
		  -- assert(seqNo < size)
		  assert(rxQueueInfo[q].size == size)	   
		  rxQueueInfo[q].recv = rxQueueInfo[q].recv + 1
		  if (rxQueueInfo[q].recv == rxQueueInfo[q].size) then
		     ackNow = true
		  end
		  assert(rxQueueInfo[q].recv <= rxQueueInfo[q].size)	    
	       end
	       if rx > 0 then
		  rxCtr:update()
		  dataRxBufs:freeAll()
	       end	 
	    end      

	    -- send ACKS if any finished
	    -- ACK when total size = recv or every rx_ack_timeout
	    do
	       local now = dpdk.getTime()
	       if ackNow then
		  local newAcks = 0
		  for q=1,perc_constants.MAX_QUEUES do
		     assert(queueInfo[q].recv <= queueInfo[q].size)
		     if queueInfo[q].recv > queueInfo[q].acked then
			newAcks = newAcks + 1 end
		  end
		  if newAcks > 0 then
		     ackTxBufs:allocN(ACK_PACKET_SIZE, newAcks)	    
		     local b = 1
		     for q=1,perc_constants.MAX_QUEUES do	 
			if rxQueueInfo[q].recv > rxQueueInfo[q].acked then
			   rxQueueInfo[q].acked = rxQueueInfo[q].recv
			   assert(b <= newAcks)
			   local pkt = txBufs[b]:getPercgPacket()
			   b = b + 1
			   pkt.payload.uint64[0] = rxQueueInfo[q].flow 
			   pkt.payload.uint64[1] = q -- lua number -> double -> 32b
			   pkt.payload.uint64[2] = rxQueueInfo[q].acked
			   pkt.payload.uint64[3] = rxQueueInfo[q].flow
			      + pkt.payload.uint64[1] + rxQueueInfo[q].recv
			   pkt.payload.uint64[4] = rxQueueInfo[q].size
			   pkt.eth:setType(eth.TYPE_ACK)
			   pkt.eth:setSrc(perc_constants.ACK_TXQUEUE)
			   pkt.eth:setDst(rxQueueInfo[q].ethSrc)
			   pkt.percg:setSource(rxQueueInfo[q].percgDst)
			   pkt.percg:setDestination(rxQueueInfo[q].percgSrc)
			end
		     end
		     txQueues[perc_constants.ACK_TXQUEUE]:send(ackTxBufs)
		  end
	       end -- ends if newAcks > 0
	    end
	 end
      end -- ends while dpdk.running()
      rxCtr:finalize()
      txCtr:finalize()
   end

   return dataMod
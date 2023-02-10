import LightningDevKit
import BitcoinDevKit


/// This is the main class for handling interactions with the Lightning Network
public class Lightning {
    
    
    var logger: MyLogger!
    var filter: MyFilter?
    var networkGraph: NetworkGraph?
    var keys_manager: KeysManager?
    var chain_monitor: ChainMonitor?
    var channel_manager_constructor: ChannelManagerConstructor?
    var channel_manager: LightningDevKit.ChannelManager?
    var channel_manager_persister: MyChannelManagerPersister
    var peer_manager: LightningDevKit.PeerManager?
    var peer_handler: TCPPeerHandler?
    
    let port = UInt16(9735)
    
    let currency: Bindings.Currency
//    let network: LDKNetwork
    let network: Bindings.Network
    var btc: Bitcoin
    
    var timer: Timer?
    
    /// Setup the LDK
    public init(btc:Bitcoin,
                getChannels: Optional<() -> [Data]> = nil,
                backUpChannel: Optional<(Data) -> ()> = nil,
                getChannelManager: Optional<() -> Data> = nil,
                backUpChannelManager: Optional<(Data) -> ()> = nil) throws {
        
        print("----- Start LDK setup -----")
        
        self.btc = btc
        
        if btc.network == Network.testnet {
            self.network = Bindings.Network.Testnet
            self.currency = Bindings.Currency.BitcoinTestnet
        }
        else {
            self.network = Bindings.Network.Bitcoin
            self.currency = Bindings.Currency.Bitcoin
        }
        
                
        // Step 1. initialize the FeeEstimator
        let feeEstimator = MyFeeEstimator()
        
        // Step 2. Initialize the Logger
        logger = MyLogger()
        
        // Step 3. Initialize the BroadcasterInterface
        let broadcaster = MyBroadcasterInterface(btc:btc)
        
        // Step 4. Initialize Persist
        let persister = MyPersister(backUpChannel: backUpChannel)
        
        // Step 5. Initialize the Transaction Filter
        filter = MyFilter()
        
        /// Step 6. Initialize the ChainMonitor
        ///
        /// What it is used for:
        ///     monitoring the chain for lightning transactions that are relevant to our node,
        ///     and broadcasting transactions
//        chain_monitor = ChainMonitor(chain_source: Option_FilterZ(value: filter),
//                                        broadcaster: broadcaster,
//                                        logger: logger,
//                                        feeest: feeEstimator,
//                                        persister: persister)
        chain_monitor = ChainMonitor(chainSource: filter, broadcaster: broadcaster, logger: logger, feeest: feeEstimator, persister: persister)
        
        /// Step 7. Initialize the KeysManager
        ///
        /// What it is used for:
        ///     providing keys for signing Lightning transactions
        let seed = btc.getPrivKey()
        let timestamp_seconds = UInt64(NSDate().timeIntervalSince1970)
        let timestamp_nanos = UInt32.init(truncating: NSNumber(value: timestamp_seconds * 1000 * 1000))
        keys_manager = KeysManager(seed: seed, startingTimeSecs: timestamp_seconds, startingTimeNanos: timestamp_nanos)
        let keysInterface = keys_manager!.asKeysInterface()
        
        /// Step 8.  Initialize the NetworkGraph
        ///
        /// You must follow this step if:
        ///     you need LDK to provide routes for sending payments (i.e. you are not providing your own routes)
        ///
        /// What it's used for:
        ///     generating routes to send payments over
        ///
        /// notes:
        ///     It will be used internally in ChannelManagerConstructor to build a NetGraphMsgHandler
        ///
        ///     If you intend to use the LDK's built-in routing algorithm,
        ///     you will need to instantiate a NetworkGraph that can later be passed to the ChannelManagerConstructor
        ///
        ///     A network graph instance needs to be provided upon initialization,
        ///     which in turn requires the genesis block hash.
        //let genesis = BestBlock.from_genesis(LDKNetwork_Testnet)
        
        
        
        // net_graph
        //var serializedNetGraph:[UInt8]? = nil
        if FileMgr.fileExists(path: "network_graph") {
//            serializedNetGraph = [UInt8]()
            let file = try FileMgr.readData(path: "network_graph")
            let readResult = NetworkGraph.read(ser: [UInt8](file), arg: logger)
            
            if readResult.isOk() {
                networkGraph = readResult.getValue()
                print("ReactNativeLDK: loaded network graph ok")
            } else {
                print("ReactNativeLDK: network graph failed to load, creating from scratch")
                print(String(describing: readResult.getError()))
                networkGraph = NetworkGraph(genesisHash: Utils.hexStringToByteArray(try btc.getGenesisHash()).reversed(), logger: logger)
//                networkGraph = NetworkGraph(genesis_hash: hexStringToByteArray("000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f").reversed(), logger: logger)
            }
//            serializedNetGraph = [UInt8](netGraphData)
        } else {
            //networkGraph = NetworkGraph(genesis_hash: [UInt8](Data(base64Encoded: try btc.getGenesisHash())!), logger: logger)
            networkGraph = NetworkGraph(genesisHash: Utils.hexStringToByteArray(try btc.getGenesisHash()).reversed(), logger: logger)
        }
        
        /// Step 9. Read ChannelMonitors from disk
        ///
        /// you must follow this step if:
        ///     if LDK is restarting and has at least 1 channel,
        ///     its channel state will need to be read from disk and fed to the ChannelManager on the next step.
        ///
        /// what it's used for:
        ///     managing channel state
        
        // channel_manager
        var serializedChannelManager:[UInt8] = [UInt8]()
        if let getChannelManager = getChannelManager {
            let channelManagerData = getChannelManager()
            serializedChannelManager = [UInt8](channelManagerData)
        } else if FileMgr.fileExists(path: "channel_manager") {
            let channelManagerData = try FileMgr.readData(path: "channel_manager")
            serializedChannelManager = [UInt8](channelManagerData)
        }
        
        // channel_monitors
        var serializedChannelMonitors:[[UInt8]] = [[UInt8]]()
        if let getChannels = getChannels {
            let channels = getChannels()
            for channel in channels {
                let channelBytes = [UInt8](channel)
                serializedChannelMonitors.append(channelBytes)
            }
        } else if FileMgr.fileExists(path: "channels") {
            let urls = try FileMgr.contentsOfDirectory(atPath:"channels")
            for url in urls {
                let channelData = try FileMgr.readData(url: url)
                let channelBytes = [UInt8](channelData)
                serializedChannelMonitors.append(channelBytes)
            }
        }
        
        
//        // net_graph
//        var serializedNetGraph:[UInt8]? = nil
//        if FileMgr.fileExists(path: "network_graph") {
//            serializedNetGraph = [UInt8]()
//            let netGraphData = try FileMgr.readData(path: "network_graph")
//            serializedNetGraph = [UInt8](netGraphData)
//        }
        
        
        /// Step 10.  Initialize the ChannelManager
        ///
        /// you must follow this step if:
        ///     this is the first time you are initializing the ChannelManager
        ///
        /// what it's used for:
        ///   managing channel state
        ///
        /// notes:
        ///
        ///     To instantiate the channel manager, we need a couple minor prerequisites.
        ///
        ///     First, we need the current block height and hash.
        ///
        ///     Second, we also need to initialize a default user config,
        ///
        ///     Finally, we can proceed by instantiating the ChannelManager using ChannelManagerConstructor.
        
        let handshakeConfig = ChannelHandshakeConfig(minimumDepthArg: 2, ourToSelfDelayArg: 144, ourHtlcMinimumMsatArg: 1, maxInboundHtlcValueInFlightPercentOfChannelArg: 10, negotiateScidPrivacyArg: false, announcedChannelArg: false, commitUpfrontShutdownPubkeyArg: true, theirChannelReserveProportionalMillionthsArg: 1)
        
        let handshakeLimits = ChannelHandshakeLimits(minFundingSatoshisArg: 0, maxFundingSatoshisArg: 20000, maxHtlcMinimumMsatArg: UInt64.max, minMaxHtlcValueInFlightMsatArg: 0, maxChannelReserveSatoshisArg: UInt64.max, minMaxAcceptedHtlcsArg: 0, maxMinimumDepthArg: 144, trustOwnFunding_0confArg: true, forceAnnouncedChannelPreferenceArg: false, theirToSelfDelayArg: 2016)
        
        let channelConfig = ChannelConfig(forwardingFeeProportionalMillionthsArg: 0, forwardingFeeBaseMsatArg: 1000, cltvExpiryDeltaArg: 72, maxDustHtlcExposureMsatArg: 5_000_000, forceCloseAvoidanceMaxFeeSatoshisArg: 1000)
        
//        handshakeConfig.set_minimum_depth(val: 1)
//        handshakeConfig.set_announced_channel(val: false)
        
//        let userConfig = UserConfig()
        let userConfig = UserConfig(channelHandshakeConfigArg: handshakeConfig, channelHandshakeLimitsArg: handshakeLimits, channelConfigArg: channelConfig, acceptForwardsToPrivChannelsArg: true, acceptInboundChannelsArg: true, manuallyAcceptInboundChannelsArg: true, acceptInterceptHtlcsArg: true)

        
//        let handshakeConfig = ChannelHandshakeConfig()
//        handshakeConfig.set_minimum_depth(val: 1)
//        handshakeConfig.set_announced_channel(val: false)
        
//        let handshakeLimits = ChannelHandshakeLimits()
//        handshakeLimits.set_force_announced_channel_preference(val: false)
        
//        userConfig.set_channel_handshake_config(val: handshakeConfig)
//        userConfig.set_channel_handshake_limits(val: handshakeLimits)
//        userConfig.set_accept_inbound_channels(val: true)
        
        // if there were no channels backup
        if let net_graph_serialized = networkGraph?.write(), !serializedChannelManager.isEmpty {
            channel_manager_constructor = try ChannelManagerConstructor(
                channelManagerSerialized: serializedChannelManager,
                channelMonitorsSerialized: serializedChannelMonitors,
                keysInterface: keysInterface,
                feeEstimator: feeEstimator,
                chainMonitor: chain_monitor!,
                filter: filter,
                netGraphSerialized: net_graph_serialized,
                txBroadcaster: broadcaster,
                logger: logger
            )
//            channel_manager_constructor = try ChannelManagerConstructor(
//                channel_manager_serialized: serializedChannelManager,
//                channel_monitors_serialized: serializedChannelMonitors,
//                keys_interface: keysInterface,
//                fee_estimator: feeEstimator,
//                chain_monitor: chain_monitor!,
//                filter: filter,
//                net_graph_serialized: net_graph_serialized,
//                tx_broadcaster: broadcaster,
//                logger: logger
//            )
        }
        else {
            let latestBlockHash = [UInt8](Data(base64Encoded: try btc.getBlockHash())!)
            let latestBlockHeight = try btc.getBlockHeight()

            channel_manager_constructor = ChannelManagerConstructor(
                network: network,
                config: userConfig,
                currentBlockchainTipHash: latestBlockHash,
                currentBlockchainTipHeight: latestBlockHeight,
                keysInterface: keysInterface,
                feeEstimator: feeEstimator,
                chainMonitor: chain_monitor!,
                netGraph: networkGraph, // see `NetworkGraph`
                txBroadcaster: broadcaster,
                logger: logger
            )
            
//            channel_manager_constructor = ChannelManagerConstructor(
//                network: network,
//                config: userConfig,
//                current_blockchain_tip_hash: latestBlockHash,
//                current_blockchain_tip_height: latestBlockHeight,
//                keys_interface: keysInterface,
//                fee_estimator: feeEstimator,
//                chain_monitor: chain_monitor!,
//                net_graph: networkGraph, // see `NetworkGraph`
//                tx_broadcaster: broadcaster,
//                logger: logger
//            )
        }
//        if serializedChannelManager.isEmpty {
//            let latestBlockHash = [UInt8](Data(base64Encoded: try btc.getBlockHash())!)
//            let latestBlockHeight = try btc.getBlockHeight()
//
//            channel_manager_constructor = ChannelManagerConstructor(
//                network: network,
//                config: userConfig,
//                current_blockchain_tip_hash: latestBlockHash,
//                current_blockchain_tip_height: latestBlockHeight,
//                keys_interface: keysInterface,
//                fee_estimator: feeEstimator,
//                chain_monitor: chain_monitor!,
//                net_graph: networkGraph, // see `NetworkGraph`
//                tx_broadcaster: broadcaster,
//                logger: logger
//            )
//        }
//        // else load the channels backup, channel manager, and net_graph
//        else {
//            channel_manager_constructor = try ChannelManagerConstructor(
//                channel_manager_serialized: serializedChannelManager,
//                channel_monitors_serialized: serializedChannelMonitors,
//                keys_interface: keysInterface,
//                fee_estimator: feeEstimator,
//                chain_monitor: chain_monitor!,
//                filter: filter,
//                net_graph_serialized: serializedNetGraph,
//                tx_broadcaster: broadcaster,
//                logger: logger
//            )
//        }
            
        channel_manager = channel_manager_constructor?.channelManager

        channel_manager_persister = MyChannelManagerPersister()
        
        /// Step 12. Sync ChannelManager and ChainMonitor to chain tip
        
        try self.sync()
        
        channel_manager_constructor?.chainSyncCompleted(persister: channel_manager_persister, scorer: nil)
        
        peer_manager = channel_manager_constructor?.peerManager
        
        peer_handler = channel_manager_constructor?.getTCPPeerHandler()
        
//        filter?.lightning = self
        
        channel_manager_persister.lightning = self
        
        startSyncTimer()
        
        
        print("---- End LDK setup -----")
    }
    
    func startSyncTimer() {
        
        self.timer?.invalidate()
        self.timer = Timer.scheduledTimer(timeInterval: 120.0, target: self, selector: #selector(sync), userInfo: nil, repeats: true)
    }
    
    @objc
    func sync() throws {
        let txids1 = channel_manager!.asConfirm().getRelevantTxids()
        let txids2 = chain_monitor!.asConfirm().getRelevantTxids()
//        let txids3 = filter!.txIds
            
//        let txIds = txids1 + txids2 + txids3
        let txIds = txids1 + txids2
        
//        let transactionSet = Set(txIds)

        if txIds.count > 0 {
            for txId in txIds {
                let txIdHex = Utils.bytesToHex32Reversed(bytes: Utils.array_to_tuple32(array: txId.0))
                let tx = self.btc.getTx(txId: txIdHex)
                if let tx = tx, tx.confirmed {
                    try transactionConfirmed(txIdHex:txIdHex, txObj: tx)
                }
                else {
                    try transactionUnconfirmed(txIdHex:txIdHex)
                }
            }
            try updateBestBlock()
        }
//        else {
//            self.timer?.invalidate()
//        }
    }
    
    func transactionUnconfirmed(txIdHex: String) throws {
        guard let channel_manager = channel_manager, let chain_monitor = chain_monitor else {
            let error = NSError(domain: "Channel manager", code: 1, userInfo: nil)
            throw error
        }
        channel_manager.asConfirm().transactionUnconfirmed(txid: Utils.hexStringToByteArray(txIdHex))
        chain_monitor.asConfirm().transactionUnconfirmed(txid: Utils.hexStringToByteArray(txIdHex))
    }
    
    func transactionConfirmed(txIdHex: String, txObj: Transaction) throws {
        guard let channel_manager = channel_manager, let chain_monitor = chain_monitor else {
            let error = NSError(domain: "Channel manager", code: 1, userInfo: nil)
            throw error
        }
        
        let height = txObj.block_height
        let txRaw = btc.getTxRaw(txId: txIdHex)
        let headerHex = btc.getBlockHeader(hash: txObj.block_hash)
        let merkleProof = btc.getTxMerkleProof(txId: txIdHex)
        let txPos = merkleProof!.pos

        //let txTuple = C2Tuple_usizeTransactionZ.new(a: UInt(truncating: txPos as NSNumber), b: [UInt8](txRaw!))
        let txTuple = (UInt(truncating: txPos as NSNumber), [UInt8](txRaw!))
        let txArray = [txTuple]

        channel_manager.asConfirm().transactionsConfirmed(header: Utils.hexStringToByteArray(headerHex!), txdata: txArray, height: UInt32(truncating: height as NSNumber))
        
        chain_monitor.asConfirm().transactionsConfirmed(header: Utils.hexStringToByteArray(headerHex!), txdata: txArray, height: UInt32(truncating: height as NSNumber))
        
    }
    
    func updateBestBlock() throws {
        guard let channel_manager = channel_manager, let chain_monitor = chain_monitor else {
            let error = NSError(domain: "Channel manager", code: 1, userInfo: nil)
            throw error
        }
        
        let best_height = btc.getTipHeight()
        let best_hash = btc.getTipHash()
        let best_header = btc.getBlockHeader(hash: best_hash!)


        channel_manager.asConfirm().bestBlockUpdated(header: Utils.hexStringToByteArray(best_header!), height: UInt32(truncating: best_height! as NSNumber))

        chain_monitor.asConfirm().bestBlockUpdated(header: Utils.hexStringToByteArray(best_header!), height: UInt32(truncating: best_height! as NSNumber))
        
    }

    
    /// Get return the node id of our node.
    ///
    /// throws:
    ///     NSError
    ///
    /// return:
    ///     the nodeId of our lightning node
    func getNodeId() throws -> String {
        if let nodeId = channel_manager?.getOurNodeId() {
            let res = Utils.bytesToHex(bytes: nodeId)
            return res
        } else {
            let error = NSError(domain: "getNodeId",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "failed to get nodeId"])
            throw error
        }
    }
    
    /// Bind node to an IP address and port.
    ///
    /// so that it can receive connection request from another node in the lightning network
    ///
    /// throws:
    ///   NSError - if there was a problem connecting
    ///
    /// return:
    ///   a boolean to indicate that binding of node was a success
    public func bindNode(_ address:String, _ port:UInt16) throws -> Bool {
        guard let peer_handler = peer_handler else {
            let error = NSError(domain: "bindNode",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "peer_handler is not available"])
            throw error
        }
        
        let res = peer_handler.bind(address: address, port: port)
        if(!res){
            let error = NSError(domain: "bindNode",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "failed to bind \(address):\(port)"])
            throw error
        }
        print("Velas/Lightning/bindNode: connected")
        print("Velas/Lightning/bindNode address: \(address)")
        print("Velas/Lightning/bindNode port: \(port)")
        return res
    }
    
    /// Bind node to local address.
    ///
    /// throws:
    ///     NSError
    ///
    /// return:
    ///     true if bind was a success
    func bindNode() throws -> Bool {
        let res = try bindNode("0.0.0.0", port)
        return res
    }
    
    /// Connect to a lightning node
    ///
    /// params:
    ///     nodeId: node id that you want to connect to
    ///     address: ip address of node
    ///     port: port of node
    ///
    /// throws:
    ///     NSError
    ///
    /// return:
    ///     true if connection went through
    func connect(nodeId: String, address: String, port: NSNumber) throws -> Bool {
        guard let peer_handler = peer_handler else {
            let error = NSError(domain: "bindNode", code: 1, userInfo: nil)
            throw error
        }
        
        let res = peer_handler.connect(address: address,
                                       port: UInt16(truncating: port),
                                       theirNodeId: Utils.hexStringToByteArray(nodeId))
        
        if (!res) {
            let error = NSError(domain: "connectPeer",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "failed to connect to peer \(nodeId)@\(address):\(port)"])
            throw error
        }
        
        return res
    }
    
    /// List peers that you are connected to.
    ///
    /// throws:
    ///     NSError
    ///
    /// return:
    ///     array of bytes that represent the node
    func listPeers() throws -> String {
        guard let peer_manager = peer_manager else {
            let error = NSError(domain: "listPeers",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "peer_manager not available"])
            throw error
        }
        
        let peer_node_ids = peer_manager.getPeerNodeIds()
        
        
        var json = "["
        var first = true
        for it in peer_node_ids {
            if (!first) { json += "," }
            first = false
            json += "\"" + Utils.bytesToHex(bytes: it) + "\""
        }
        json += "]"
        
        return json
    }
    
    /// Get list of channels that were established with partner node.
    func listChannels() throws -> String {
        guard let channel_manager = channel_manager else {
            let error = NSError(domain: "listChannels",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Channel Manager not initialized"])
            throw error
        }

        let channels = channel_manager.listChannels().isEmpty ? [] : channel_manager.listChannels()
        var jsonArray = "["
        var first = true
        _ = channels.map { (it: ChannelDetails) in
            let channelObject = self.channel2ChannelObject(it: it)

            if (!first) { jsonArray += "," }
            jsonArray += channelObject
            first = false
        }

        jsonArray += "]"
        return jsonArray
    }
    
    
    /// Convert ChannelDetails to a string
    func channel2ChannelObject(it: ChannelDetails) -> String {
        let short_channel_id = it.getShortChannelId() ?? 0
        let confirmations_required = it.getConfirmationsRequired() ?? 0;
        let force_close_spend_delay = it.getForceCloseSpendDelay() ?? 0;
        let unspendable_punishment_reserve = it.getUnspendablePunishmentReserve() ?? 0;

        var channelObject = "{"
        channelObject += "\"channel_id\":" + "\"" + Utils.bytesToHex(bytes: it.getChannelId()!) + "\","
        channelObject += "\"channel_value_satoshis\":" + String(it.getChannelValueSatoshis()) + ","
        channelObject += "\"inbound_capacity_msat\":" + String(it.getInboundCapacityMsat()) + ","
        channelObject += "\"outbound_capacity_msat\":" + String(it.getOutboundCapacityMsat()) + ","
        channelObject += "\"short_channel_id\":" + "\"" + String(short_channel_id) + "\","
        channelObject += "\"is_usable\":" + (it.getIsUsable() ? "true" : "false") + ","
        channelObject += "\"is_channel_ready\":" + (it.getIsChannelReady() ? "true" : "false") + ","
        channelObject += "\"is_outbound\":" + (it.getIsOutbound() ? "true" : "false") + ","
        channelObject += "\"is_public\":" + (it.getIsPublic() ? "true" : "false") + ","
        channelObject += "\"remote_node_id\":" + "\"" + Utils.bytesToHex(bytes: it.getCounterparty().getNodeId()) + "\"," // @deprecated fixme

        // fixme:
        if let funding_txo = it.getFundingTxo() {
            channelObject += "\"funding_txo_txid\":" + "\"" + Utils.bytesToHex(bytes: funding_txo.getTxid()!) + "\","
            channelObject += "\"funding_txo_index\":" + String(funding_txo.getIndex()) + ","
        }else{
            channelObject += "\"funding_txo_txid\": null,"
            channelObject += "\"funding_txo_index\": null,"
        }

        channelObject += "\"counterparty_unspendable_punishment_reserve\":" + String(it.getCounterparty().getUnspendablePunishmentReserve()) + ","
        channelObject += "\"counterparty_node_id\":" + "\"" + Utils.bytesToHex(bytes: it.getCounterparty().getNodeId()) + "\","
        channelObject += "\"unspendable_punishment_reserve\":" + String(unspendable_punishment_reserve) + ","
        channelObject += "\"confirmations_required\":" + String(confirmations_required) + ","
        channelObject += "\"force_close_spend_delay\":" + String(force_close_spend_delay) + ","
        //channelObject += "\"user_id\":" + String(it.getUserChannelId()!) + ","
        channelObject += "\"counterparty_node_id\":" + Utils.bytesToHex(bytes: it.getCounterparty().getNodeId())
        channelObject += "}"

        return channelObject
    }
    
    /// Close all channels in the nice way, cooperatively.
    func closeChannelsCooperatively() throws {
        guard let channel_manager = channel_manager else {
            let error = NSError(domain: "closeChannels",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Channel Manager not initialized"])
            throw error
        }

        let channels = channel_manager.listChannels().isEmpty ? [] : channel_manager.listChannels()
       
        
        _ = try channels.map { (channel: ChannelDetails) in
            try closeChannelCooperatively(nodeId: channel.getCounterparty().getNodeId(),
                                      channelId: channel.getChannelId()!)
        }
    }
    
    /// Close a channel in the nice way, cooperatively.
    ///
    /// both parties aggree to close the channel
    ///
    /// throws:
    ///     NSError
    ///
    /// return:
    ///     true if close correctly
    func closeChannelCooperatively(nodeId: [UInt8], channelId: [UInt8]) throws -> Bool {
        guard let close_result = channel_manager?.closeChannel(channelId: channelId, counterpartyNodeId: nodeId), close_result.isOk() else {
            let error = NSError(domain: "closeChannelCooperatively",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "closeChannelCooperatively Failed"])
            throw error
        }
        try removeChannelBackup(channelId: Utils.bytesToHex(bytes: channelId))
        
        return true
    }
    
    /// Close all channels the ugly way, forcefully.
    func closeChannelsForcefully() throws {
        guard let channel_manager = channel_manager else {
            let error = NSError(domain: "closeChannels",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Channel Manager not initialized"])
            throw error
        }

        let channels = channel_manager.listChannels().isEmpty ? [] : channel_manager.listChannels()
       
        
        _ = try channels.map { (channel: ChannelDetails) in
            try closeChannelForcefully(nodeId: channel.getCounterparty().getNodeId(),
                                      channelId: channel.getChannelId()!)
        }
    }
    
    /// Close a channel the bad way, forcefully.
    ///
    /// force to close the channel due to maybe the other peer being unresponsive
    ///
    /// throws:
    ///     NSError
    ///
    /// return:
    ///     true is channel was closed
    func closeChannelForcefully(nodeId: [UInt8], channelId: [UInt8]) throws -> Bool {
        guard let close_result = channel_manager?.forceCloseBroadcastingLatestTxn(channelId: channelId, counterpartyNodeId: nodeId) else {
            let error = NSError(domain: "closeChannelForce",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "closeChannelForce Failed"])
            throw error
        }
        if (close_result.isOk()) {
            try removeChannelBackup(channelId: Utils.bytesToHex(bytes: channelId))
            return true
        } else {
            let error = NSError(domain: "closeChannelForce",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "closeChannelForce Failed"])
            throw error
        }
    }
    
    func removeChannelBackup(channelId:String) throws {
        print("try to delete channel: \(channelId)")
        do {
            let urls = try FileMgr.contentsOfDirectory(atPath:"channels")
            for url in urls {
                print(url)
                if url.lastPathComponent.contains(channelId) {
                    print("delete url:\(url)")
                    try FileMgr.removeItem(url: url)
                }
            }
        }
        catch {
            print("remove channel backup: \(error)")
        }
    }
    
    /// Create Bolt11 Invoice.
    ///
    /// params:
    ///     amtMsat:  amount in mili satoshis
    ///     description:  descrition of invoice
    ///
    /// returns:
    ///     bolt11 invoice
    ///
    /// throws:
    ///     NSError
    func createInvoice(amtMsat: Int, description: String) throws -> String {
        
        guard let channel_manager = channel_manager, let keys_manager = keys_manager else {
            let error = NSError(domain: "addInvoice",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "No channel_manager or keys_manager initialized"])
            throw error
        }
        
        let invoiceResult = Bindings.swiftCreateInvoiceFromChannelmanager(
            channelmanager: channel_manager,
            keysManager: keys_manager.asKeysInterface(),
            logger: logger,
            network: currency,
            amtMsat: UInt64(exactly: amtMsat),
            description: description,
            invoiceExpiryDeltaSecs: 24 * 3600)

        if let invoice = invoiceResult.getValue() {
            return invoice.toStr()
        } else {
            let error = NSError(domain: "addInvoice",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "addInvoice failed"])
            throw error
        }
    }
    
    /// Pay a bolt11 invoice.
    ///
    /// params:
    ///     bolt11: the bolt11 invoice we want to pay
    ///     amtMSat: amount we want to pay in milisatoshis
    ///
    /// throws:
    ///     NSError
    ///
    /// return:
    ///     true is payment when through
    func payInvoice(bolt11: String) throws -> Bool {

        guard let payer = channel_manager_constructor?.payer else {
            let error = NSError(domain: "payInvoice", code: 1, userInfo: nil)
            throw error
        }

        let parsedInvoice = Invoice.fromStr(s: bolt11)

        guard let parsedInvoiceValue = parsedInvoice.getValue(), parsedInvoice.isOk() else {
            let error = NSError(domain: "payInvoice", code: 1, userInfo: nil)
            throw error
        }

        if let _ = parsedInvoiceValue.amountMilliSatoshis() {
            let sendRes = payer.payInvoice(invoice: parsedInvoiceValue)
            if sendRes.isOk() {
                return true
            } else {
                print("pay_invoice error")
                print(String(describing: sendRes.getError()))
            }
        } else {
            
            let error = NSError(domain: "payInvoice", code: 1, userInfo: nil)
            throw error
        }
        
        return true
    }

}











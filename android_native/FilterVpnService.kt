package com.adshield.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * 本地 VPN + DNS 过滤核心服务（AdGuard / personalDNSfilter 同类方案）。
 *
 * 原理：
 * 1. 建立一个仅路由 DNS 流量（本机回环假 DNS + 常见硬编码 DNS IP）的本地 VPN；
 * 2. 从 tun 读取 UDP/53 数据包，解析出待解析域名；
 * 3. 命中黑名单 → 直接返回 NXDOMAIN；命中白名单或未命中 → 转发到上游 DNS；
 * 4. 上游应答重新封装 IP/UDP 包写回 tun。
 *
 * 无需 Root；非 DNS 流量不进隧道，不影响网速。
 */
class FilterVpnService : VpnService() {

    companion object {
        private const val TAG = "FilterVpnService"
        private const val CHANNEL_ID = "adshield_vpn"
        private const val NOTIFICATION_ID = 1

        /// 假 DNS 地址（指向本机隧道，IPv4 / IPv6 各一）
        private const val FAKE_DNS = "10.111.222.3"
        private const val FAKE_DNS6 = "fd00:53ad::1"

        /// 假 DNS 地址的字节形式（用于快速比对，避免逐包调用 InetAddress）
        private val FAKE_DNS_BYTES = InetAddress.getByName(FAKE_DNS).address
        private val FAKE_DNS6_BYTES = InetAddress.getByName(FAKE_DNS6).address

        // 历史教训：曾把 8.8.8.8 / 114.114.114.114 / 223.5.5.5 等硬编码 DNS IP 整段
        // 路由进隧道"防绕过"，导致发往这些 IP 的 DoH/DoT/TCP 流量被黑洞丢弃，
        // 用加密 DNS 的应用全部超时重试、全机变慢。现已改为只路由假 DNS 地址，
        // 应用自带加密 DNS 时让其直连（不过滤），优先保证系统整体网络体验。

        @JvmStatic
        val isRunning = AtomicBoolean(false)

        @JvmStatic
        val blockedCount = AtomicLong(0)

        @JvmStatic
        val allowedCount = AtomicLong(0)

        @JvmStatic
        val totalBlocked = AtomicLong(0)

        @JvmStatic
        var instance: FilterVpnService? = null
    }

    private var tun: ParcelFileDescriptor? = null
    private var worker: Thread? = null
    private val dnsPool = Executors.newCachedThreadPool()

    /// DNS 响应缓存：key = "域名/记录类型"，TTL 内命中直接回包，避免重复走上游转发链路
    private class CacheEntry(val reply: ByteArray, val expiresAt: Long)
    private val dnsCache = java.util.concurrent.ConcurrentHashMap<String, CacheEntry>()

    private var blockSet: MutableSet<String> = HashSet()
    private var allowSet: MutableSet<String> = HashSet()
    private var upstreamDns = "223.5.5.5"

    // ------------------------------------------------------------------
    // 生命周期
    // ------------------------------------------------------------------

    override fun onCreate() {
        super.onCreate()
        instance = this
        loadRules()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "STOP" -> {
                stopSelf()
                return START_NOT_STICKY
            }
            else -> startVpn()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning.set(false)
        teardown()
        instance = null
        super.onDestroy()
    }

    // ------------------------------------------------------------------
    // 规则加载
    // ------------------------------------------------------------------

    fun loadRules() {
        try {
            val dir = filesDir
            blockSet = File(dir, "blocklist.txt").takeIf { it.exists() }
                ?.readLines()
                ?.mapNotNull { l -> l.trim().takeIf { it.isNotEmpty() && !it.startsWith("#") } }
                ?.toMutableSet() ?: HashSet()
            allowSet = File(dir, "allowlist.txt").takeIf { it.exists() }
                ?.readLines()
                ?.map { it.trim().lowercase() }
                ?.filter { it.isNotEmpty() }
                ?.toMutableSet() ?: HashSet()
            val config = File(dir, "config.json")
            if (config.exists()) {
                try {
                    upstreamDns = JSONObject(config.readText())
                        .optString("upstreamDns", upstreamDns)
                } catch (_: Exception) { }
            }
            blockSet.removeAll(allowSet)
            Log.i(TAG, "规则已加载: ${blockSet.size} 条拦截 / ${allowSet.size} 条放行 / 上游 $upstreamDns")
        } catch (e: Exception) {
            Log.e(TAG, "规则加载失败", e)
        }
    }

    // ------------------------------------------------------------------
    // VPN 建立
    // ------------------------------------------------------------------

    private fun startVpn() {
        if (isRunning.get()) return
        val notificationManager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            notificationManager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "广告拦截", NotificationManager.IMPORTANCE_LOW
                )
            )
        }
        val intent = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        val notification: Notification =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                // Android 8+ 必须使用带渠道 ID 的构造器，否则 startForeground 抛
                // RemoteServiceException: Bad notification（Android 12 起强制校验）
                Notification.Builder(this, CHANNEL_ID)
                    .setContentTitle("AdShield 正在拦截广告")
                    .setContentText("DNS 过滤运行中")
                    .setSmallIcon(android.R.drawable.stat_notify_more)
                    .setContentIntent(intent)
                    .setOngoing(true)
                    .build()
            } else {
                Notification.Builder(this)
                    .setContentTitle("AdShield 正在拦截广告")
                    .setContentText("DNS 过滤运行中")
                    .setSmallIcon(android.R.drawable.stat_notify_more)
                    .setContentIntent(intent)
                    .build()
            }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        val builder = Builder()
            .setSession("AdShield")
            .setMtu(1500)
            .addAddress("10.111.222.1", 32)
            .addDnsServer(FAKE_DNS)
        // IPv6 栈：系统 DNS 走假地址，全部经过滤引擎处理
        .addAddress(FAKE_DNS6, 64)
        .addDnsServer(FAKE_DNS6)
        // 只把假 DNS 地址路由进隧道（/32 精确匹配），其余全部流量直连。
        // 注意：绝不路由 8.8.8.8 / 114 等硬编码 DNS IP——那会把发往这些 IP 的
        // DoH(443)/DoT(853)/TCP 流量也吸进隧道并被丢弃，造成应用 DNS 黑洞、全机变慢。
        // 应用自带加密 DNS 时让其直连（不过滤），优先保证系统整体网络体验。
        builder.addRoute(FAKE_DNS, 32)
        builder.addRoute(FAKE_DNS6, 128)

        try {
            tun = builder.establish() ?: run {
                Log.e(TAG, "establish() 返回 null：VPN 权限被拒绝")
                isRunning.set(false)
                stopSelf()
                return
            }
        } catch (e: Exception) {
            Log.e(TAG, "establish() 异常", e)
            isRunning.set(false)
            stopSelf()
            return
        }

        isRunning.set(true)
        worker = Thread(::packetLoop, "vpn-packet-loop").apply { start() }
        Log.i(TAG, "VPN 已启动")
    }

    private fun teardown() {
        isRunning.set(false)
        worker?.interrupt()
        worker = null
        try {
            tun?.close()
        } catch (_: Exception) { }
        tun = null
        dnsPool.shutdownNow()
    }

    // ------------------------------------------------------------------
    // 数据包主循环
    // ------------------------------------------------------------------

    private fun packetLoop() {
        val input = FileInputStream(tun!!.fileDescriptor)
        val output = FileOutputStream(tun!!.fileDescriptor)
        val buffer = ByteArray(32767)

        while (isRunning.get() && !Thread.currentThread().isInterrupted) {
            try {
                val length = input.read(buffer)
                if (length <= 0) continue
                handlePacket(buffer, length, output)
            } catch (e: InterruptedException) {
                break
            } catch (e: Exception) {
                Log.w(TAG, "处理数据包异常: ${e.message}")
            }
        }
    }

    /// 从 tun 读到的数据包上下文（IPv4/IPv6 统一抽象）
    private class DnsExchange(
        val version: Int,        // 4 或 6
        val srcIp: ByteArray,    // 4 或 16 字节
        val dstIp: ByteArray,
        val srcPort: Int,
        val dstPort: Int,
        val dnsMsg: ByteArray,
    )

    private fun handlePacket(buffer: ByteArray, length: Int, output: FileOutputStream) {
        if (length < 40) return
        val version = (buffer[0].toInt() shr 4) and 0xF
        // 发往假 DNS 的 TCP（系统"私人 DNS"机会式 DoT 探测、TCP DNS 等）：
        // 立即回 RST，客户端秒退回明文 UDP，避免黑洞等待超时拖慢系统
        if (isTcpToFakeDns(buffer, length, version)) {
            buildTcpRst(buffer, length, version)?.let { writePacket(output, it) }
            return
        }
        val exchange = parsePacket(buffer, length) ?: return
        val query = parseDnsQuery(exchange.dnsMsg) ?: return
        if (query.name.isEmpty()) return

        val blocked = isBlocked(query.name)
        if (blocked) {
            blockedCount.incrementAndGet()
            totalBlocked.incrementAndGet()
            persistStats()
            writePacket(output, buildReply(exchange, blockedResponse(query)))
        } else {
            allowedCount.incrementAndGet()
            // 缓存命中：跳过 socket 转发，直接回包（写回时需改写事务 ID 为本次查询的 ID）
            val cacheKey = query.name + "/" + query.qtype
            val hit = dnsCache[cacheKey]?.takeIf { System.currentTimeMillis() < it.expiresAt }
            if (hit != null) {
                writePacket(output, buildReply(exchange, withQueryId(hit.reply, query.id)))
            } else {
                dnsPool.execute {
                    val reply = forwardToUpstream(exchange.dnsMsg)
                    if (reply != null) {
                        storeInCache(cacheKey, reply)
                        try {
                            writePacket(output, buildReply(exchange, reply))
                        } catch (_: Exception) { }
                    }
                }
            }
        }
    }

    /// 判断是否为发往假 DNS 地址的 TCP 包
    private fun isTcpToFakeDns(buffer: ByteArray, length: Int, version: Int): Boolean {
        val protoIdx: Int
        val dstStart: Int
        val addrLen: Int
        when (version) {
            4 -> { if (length < 24) return false; protoIdx = 9; dstStart = 16; addrLen = 4 }
            6 -> { if (length < 44) return false; protoIdx = 6; dstStart = 24; addrLen = 16 }
            else -> return false
        }
        if ((buffer[protoIdx].toInt() and 0xFF) != 6) return false // 仅 TCP
        val dst = buffer.copyOfRange(dstStart, dstStart + addrLen)
        return dst.contentEquals(FAKE_DNS_BYTES) || dst.contentEquals(FAKE_DNS6_BYTES)
    }

    /// 构造 TCP RST 应答（对 SYN 立即拒绝，让 DoT/TCP-DNS 客户端快速回退明文 UDP）
    private fun buildTcpRst(buffer: ByteArray, length: Int, version: Int): ByteArray? {
        val tcpStart: Int
        val srcIp: ByteArray
        val dstIp: ByteArray
        when (version) {
            4 -> {
                val ihl = (buffer[0].toInt() and 0xF) * 4
                if (ihl < 20 || length < ihl + 20) return null
                tcpStart = ihl
                srcIp = buffer.copyOfRange(12, 16)
                dstIp = buffer.copyOfRange(16, 20)
            }
            6 -> {
                if (length < 60) return null
                tcpStart = 40
                srcIp = buffer.copyOfRange(8, 24)
                dstIp = buffer.copyOfRange(24, 40)
            }
            else -> return null
        }
        val flags = buffer[tcpStart + 13].toInt() and 0xFF
        if (flags and 0x02 == 0) return null // 仅对 SYN 回 RST，其余忽略

        val srcPort = ((buffer[tcpStart].toInt() and 0xFF) shl 8) or (buffer[tcpStart + 1].toInt() and 0xFF)
        val dstPort = ((buffer[tcpStart + 2].toInt() and 0xFF) shl 8) or (buffer[tcpStart + 3].toInt() and 0xFF)
        val seq = (((buffer[tcpStart + 4].toInt() and 0xFF) shl 24) or
                ((buffer[tcpStart + 5].toInt() and 0xFF) shl 16) or
                ((buffer[tcpStart + 6].toInt() and 0xFF) shl 8) or
                (buffer[tcpStart + 7].toInt() and 0xFF)).toLong() and 0xFFFFFFFFL

        val ipHdrLen = if (version == 4) 20 else 40
        val out = ByteArray(ipHdrLen + 20)
        val t = ipHdrLen

        // TCP 头：RST+ACK，seq=0（SYN 无 ACK），ack=对端 seq+1
        out[t] = (dstPort shr 8).toByte(); out[t + 1] = dstPort.toByte()
        out[t + 2] = (srcPort shr 8).toByte(); out[t + 3] = srcPort.toByte()
        out[t + 4] = 0; out[t + 5] = 0; out[t + 6] = 0; out[t + 7] = 0          // seq = 0
        out[t + 8] = ((seq + 1) shr 24).toByte(); out[t + 9] = ((seq + 1) shr 16).toByte()
        out[t + 10] = ((seq + 1) shr 8).toByte(); out[t + 11] = (seq + 1).toByte() // ack = seq+1
        out[t + 12] = 0x50                                                       // 数据偏移 5×4=20
        out[t + 13] = 0x14                                                       // RST|ACK
        out[t + 14] = 0; out[t + 15] = 0                                         // window = 0
        out[t + 16] = 0; out[t + 17] = 0                                         // 校验和后填
        out[t + 18] = 0; out[t + 19] = 0                                         // urgent = 0

        if (version == 4) {
            val totalLen = ipHdrLen + 20
            out[0] = 0x45; out[1] = 0
            out[2] = (totalLen shr 8).toByte(); out[3] = totalLen.toByte()
            out[4] = 0; out[5] = 0; out[6] = 0x40; out[7] = 0
            out[8] = 64; out[9] = 6
            srcIp.copyInto(out, 12); dstIp.copyInto(out, 16)
            val ipCk = checksum(out, 0, 20)
            out[10] = ((ipCk shr 8) and 0xFF).toByte(); out[11] = (ipCk and 0xFF).toByte()
        } else {
            out[0] = 0x60; out[1] = 0; out[2] = 0; out[3] = 0
            out[4] = 0; out[5] = 20                       // payload len = 20
            out[6] = 6                                    // next header TCP
            out[7] = 64                                   // hop limit
            srcIp.copyInto(out, 8); dstIp.copyInto(out, 24)
        }

        // TCP 校验和（伪首部）
        val pseudo = ByteArray(20 + 40)
        when (version) {
            4 -> {
                srcIp.copyInto(pseudo, 0); dstIp.copyInto(pseudo, 4)
                pseudo[8] = 0; pseudo[9] = 6
                pseudo[10] = 0; pseudo[11] = 20
                out.copyInto(pseudo, 12, t, t + 20)
            }
            else -> {
                srcIp.copyInto(pseudo, 0); dstIp.copyInto(pseudo, 16)
                pseudo[32] = 0; pseudo[33] = 0; pseudo[34] = 0; pseudo[35] = 6
                pseudo[36] = 0; pseudo[37] = 0; pseudo[38] = 0; pseudo[39] = 20
                out.copyInto(pseudo, 40, t, t + 20)
            }
        }
        var c = checksum(pseudo, 0, when (version) { 4 -> 32; else -> 60 })
        if (c == 0) c = 0xFFFF
        out[t + 16] = ((c shr 8) and 0xFF).toByte()
        out[t + 17] = (c and 0xFF).toByte()
        return out
    }

    /// 解析 IPv4/IPv6 + UDP/53 数据包；非 DNS 或带扩展头的 IPv6 返回 null
    private fun parsePacket(buffer: ByteArray, length: Int): DnsExchange? {
        val version = (buffer[0].toInt() shr 4) and 0xF
        return when (version) {
            4 -> parseV4(buffer, length)
            6 -> parseV6(buffer, length)
            else -> null
        }
    }

    private fun parseV4(buffer: ByteArray, length: Int): DnsExchange? {
        val ihl = (buffer[0].toInt() and 0xF) * 4
        if (ihl < 20 || length < ihl + 8) return null
        if ((buffer[9].toInt() and 0xFF) != 17) return null // 仅 UDP

        val udpStart = ihl
        val srcPort = ((buffer[udpStart].toInt() and 0xFF) shl 8) or
                (buffer[udpStart + 1].toInt() and 0xFF)
        val dstPort = ((buffer[udpStart + 2].toInt() and 0xFF) shl 8) or
                (buffer[udpStart + 3].toInt() and 0xFF)
        val udpLen = ((buffer[udpStart + 4].toInt() and 0xFF) shl 8) or
                (buffer[udpStart + 5].toInt() and 0xFF)
        if (dstPort != 53 || udpLen < 8) return null

        val dnsStart = udpStart + 8
        val dnsEnd = udpStart + udpLen
        if (dnsEnd > length) return null

        return DnsExchange(
            version = 4,
            srcIp = buffer.copyOfRange(12, 16),
            dstIp = buffer.copyOfRange(16, 20),
            srcPort = srcPort,
            dstPort = dstPort,
            dnsMsg = buffer.copyOfRange(dnsStart, dnsEnd),
        )
    }

    private fun parseV6(buffer: ByteArray, length: Int): DnsExchange? {
        // IPv6 固定头 40 字节；MVP 不处理扩展头（绝大多数 DNS 查询紧跟 UDP）
        if (length < 48) return null
        if ((buffer[6].toInt() and 0xFF) != 17) return null // nextHeader != UDP

        val udpStart = 40
        val srcPort = ((buffer[udpStart].toInt() and 0xFF) shl 8) or
                (buffer[udpStart + 1].toInt() and 0xFF)
        val dstPort = ((buffer[udpStart + 2].toInt() and 0xFF) shl 8) or
                (buffer[udpStart + 3].toInt() and 0xFF)
        val udpLen = ((buffer[udpStart + 4].toInt() and 0xFF) shl 8) or
                (buffer[udpStart + 5].toInt() and 0xFF)
        if (dstPort != 53 || udpLen < 8) return null

        val dnsStart = udpStart + 8
        val dnsEnd = udpStart + udpLen
        if (dnsEnd > length) return null

        return DnsExchange(
            version = 6,
            srcIp = buffer.copyOfRange(8, 24),
            dstIp = buffer.copyOfRange(24, 40),
            srcPort = srcPort,
            dstPort = dstPort,
            dnsMsg = buffer.copyOfRange(dnsStart, dnsEnd),
        )
    }

    private fun isBlocked(domain: String): Boolean {
        if (domain in allowSet) return false
        var d = domain
        while (true) {
            if (d in blockSet) return true
            val idx = d.indexOf('.')
            if (idx <= 0) return false
            d = d.substring(idx + 1)
        }
    }

    /// 将应答数据包写回 tun 设备（多线程写需同步）
    private fun writePacket(output: FileOutputStream, packet: ByteArray) {
        synchronized(output) {
            output.write(packet)
            output.flush()
        }
    }

    private fun forwardToUpstream(dnsMsg: ByteArray): ByteArray? {
        var socket: DatagramSocket? = null
        return try {
            socket = DatagramSocket()
            protect(socket) // 关键：让上游流量绕过本 VPN，避免回环
            socket.soTimeout = 3000
            val addr = InetAddress.getByName(upstreamDns)
            socket.send(DatagramPacket(dnsMsg, dnsMsg.size, addr, 53))
            val buf = ByteArray(4096)
            val packet = DatagramPacket(buf, buf.size)
            socket.receive(packet)
            buf.copyOfRange(0, packet.length)
        } catch (e: Exception) {
            Log.w(TAG, "上游 DNS 转发失败: ${e.message}")
            null
        } finally {
            socket?.close()
        }
    }

    // ------------------------------------------------------------------
    // DNS 解析与应答
    // ------------------------------------------------------------------

    private class DnsQuery(val id: Int, val name: String, val qtype: Int, val rawQuestion: ByteArray)

    private fun parseDnsQuery(msg: ByteArray): DnsQuery? {
        if (msg.size < 12) return null
        val qr = (msg[2].toInt() shr 7) and 0x1
        if (qr != 0) return null // 仅处理查询
        val id = ((msg[0].toInt() and 0xFF) shl 8) or (msg[1].toInt() and 0xFF)
        var i = 12
        val labels = ArrayList<String>()
        while (true) {
            if (i >= msg.size) return null
            val len = msg[i].toInt() and 0xFF
            if (len == 0) { i += 1; break }
            if (len > 63 || i + 1 + len > msg.size) return null
            labels.add(String(msg, i + 1, len, Charsets.US_ASCII))
            i += 1 + len
        }
        if (i + 4 > msg.size) return null
        // question 末尾 4 字节 = QTYPE(2) + QCLASS(2)
        val qtype = ((msg[i].toInt() and 0xFF) shl 8) or (msg[i + 1].toInt() and 0xFF)
        return DnsQuery(id, labels.joinToString(".").lowercase(), qtype,
            msg.copyOfRange(0, i + 4))
    }

    /// NXDOMAIN 应答：复用原查询的 header + question
    private fun blockedResponse(q: DnsQuery): ByteArray {
        val out = q.rawQuestion.copyOf()
        out[2] = 0x81.toByte(); out[3] = 0x83.toByte() // QR=1 RD=1 RCODE=3(NXDOMAIN)
        out[6] = 0; out[7] = 0  // ANCOUNT = 0
        out[8] = 0; out[9] = 0  // NSCOUNT = 0
        out[10] = 0; out[11] = 0 // ARCOUNT = 0
        return out
    }

    /// 把应答报文的事务 ID 改写为本次查询的 ID（缓存命中时与当初查询的 ID 不同）
    private fun withQueryId(reply: ByteArray, id: Int): ByteArray {
        val out = reply.copyOf()
        out[0] = ((id shr 8) and 0xFF).toByte()
        out[1] = (id and 0xFF).toByte()
        return out
    }

    /// 解析上游应答各资源记录的最小 TTL（秒），作为缓存有效期；无应答记录或解析失败返回 null
    private fun parseMinTtl(msg: ByteArray): Long? {
        if (msg.size < 12) return null
        var count = ((msg[6].toInt() and 0xFF) shl 8) or (msg[7].toInt() and 0xFF)
        if (count == 0) return null
        var i = 12
        // 跳过 question 区（问题段一般无压缩指针，稳妥起见也处理）
        while (i < msg.size) {
            val len = msg[i].toInt() and 0xFF
            if (len == 0) { i += 1; break }
            if ((len and 0xC0) == 0xC0) { i += 2; break }
            i += 1 + len
        }
        i += 4 // QTYPE + QCLASS
        var minTtl: Long? = null
        while (count > 0 && i < msg.size) {
            // 跳过资源记录名（可能含压缩指针 0xC0 前缀）
            var j = i
            var jumps = 0
            while (j < msg.size) {
                val len = msg[j].toInt() and 0xFF
                if (len == 0) { j += 1; break }
                if ((len and 0xC0) == 0xC0) { j += 2; break }
                j += 1 + len
                if (++jumps > 64) return null
            }
            if (j + 10 > msg.size) return null
            val ttl = (((msg[j + 4].toInt() and 0xFF) shl 24) or
                    ((msg[j + 5].toInt() and 0xFF) shl 16) or
                    ((msg[j + 6].toInt() and 0xFF) shl 8) or
                    (msg[j + 7].toInt() and 0xFF)).toLong() and 0xFFFFFFFFL
            if (minTtl == null || ttl < minTtl) minTtl = ttl
            val rdlen = ((msg[j + 8].toInt() and 0xFF) shl 8) or (msg[j + 9].toInt() and 0xFF)
            i = j + 10 + rdlen
            count--
        }
        return minTtl
    }

    /// 写入缓存：TTL 收敛在 30 秒 ~ 10 分钟（过短无意义，过长避免 CDN 切换后拿到旧节点）；
    /// NXDOMAIN（rcode 3）负缓存 60 秒，避免反复请求失效域名；SERVFAIL 等其它错误不缓存
    private fun storeInCache(key: String, reply: ByteArray) {
        val expiresAt: Long = if (reply.size >= 4 && (reply[3].toInt() and 0xF) == 3) {
            System.currentTimeMillis() + 60_000L
        } else {
            val ttl = parseMinTtl(reply) ?: return
            System.currentTimeMillis() + ttl.coerceIn(30, 600) * 1000
        }
        if (dnsCache.size >= 1024) {
            val now = System.currentTimeMillis()
            dnsCache.values.removeIf { it.expiresAt <= now }
            if (dnsCache.size >= 1024) dnsCache.clear()
        }
        dnsCache[key] = CacheEntry(reply, expiresAt)
    }

    // ------------------------------------------------------------------
    // IP / UDP 封包
    // ------------------------------------------------------------------

    /// 按请求包的 IP 版本构造应答
    private fun buildReply(exchange: DnsExchange, payload: ByteArray): ByteArray =
        if (exchange.version == 4) {
            buildUdp4Packet(exchange.srcIp, exchange.dstIp,
                exchange.srcPort, exchange.dstPort, payload)
        } else {
            buildUdp6Packet(exchange.srcIp, exchange.dstIp,
                exchange.srcPort, exchange.dstPort, payload)
        }

    private fun buildUdp4Packet(
        srcIp: ByteArray, dstIp: ByteArray, srcPort: Int, dstPort: Int, payload: ByteArray
    ): ByteArray {
        val udpLen = 8 + payload.size
        val totalLen = 20 + udpLen
        val out = ByteArray(totalLen)

        // IPv4 头
        out[0] = 0x45
        out[1] = 0
        out[2] = (totalLen shr 8).toByte()
        out[3] = totalLen.toByte()
        out[4] = 0; out[5] = 0       // identification
        out[6] = 0x40; out[7] = 0    // don't fragment
        out[8] = 64.toByte()         // ttl
        out[9] = 17.toByte()         // protocol UDP
        srcIp.copyInto(out, 12)
        dstIp.copyInto(out, 16)
        val ipChecksum = checksum(out, 0, 20)
        out[10] = ((ipChecksum shr 8) and 0xFF).toByte()
        out[11] = (ipChecksum and 0xFF).toByte()
        writeUdpHeaderAndPayload(out, 20, srcPort, dstPort, payload)

        // UDP 校验和（含 IPv4 伪首部）
        val pseudo = ByteArray(12 + 8 + payload.size)
        srcIp.copyInto(pseudo, 0)
        dstIp.copyInto(pseudo, 4)
        pseudo[8] = 0; pseudo[9] = 17
        pseudo[10] = (udpLen shr 8).toByte()
        pseudo[11] = udpLen.toByte()
        out.copyInto(pseudo, 12, 20, 20 + udpLen)
        var c = checksum(pseudo, 0, pseudo.size)
        if (c == 0) c = 0xFFFF
        out[26] = ((c shr 8) and 0xFF).toByte()
        out[27] = (c and 0xFF).toByte()
        return out
    }

    private fun buildUdp6Packet(
        srcIp: ByteArray, dstIp: ByteArray, srcPort: Int, dstPort: Int, payload: ByteArray
    ): ByteArray {
        val udpLen = 8 + payload.size
        val totalLen = 40 + udpLen
        val out = ByteArray(totalLen)

        // IPv6 头（无首部校验和）
        out[0] = 0x60
        out[1] = 0; out[2] = 0; out[3] = 0       // traffic class / flow label
        out[4] = (udpLen shr 8).toByte()
        out[5] = udpLen.toByte()
        out[6] = 17.toByte()                      // nextHeader UDP
        out[7] = 64.toByte()                      // hop limit
        srcIp.copyInto(out, 8)
        dstIp.copyInto(out, 24)
        writeUdpHeaderAndPayload(out, 40, srcPort, dstPort, payload)

        // IPv6 强制要求 UDP 校验和：伪首部 128 位地址
        val pseudo = ByteArray(40 + 8 + payload.size)
        srcIp.copyInto(pseudo, 0)
        dstIp.copyInto(pseudo, 16)
        pseudo[32] = (udpLen shr 24).toByte()
        pseudo[33] = ((udpLen shr 16) and 0xFF).toByte()
        pseudo[34] = ((udpLen shr 8) and 0xFF).toByte()
        pseudo[35] = (udpLen and 0xFF).toByte()
        pseudo[36] = 0; pseudo[37] = 0; pseudo[38] = 0
        pseudo[39] = 17
        out.copyInto(pseudo, 40, 40, 40 + udpLen)
        var c = checksum(pseudo, 0, pseudo.size)
        if (c == 0) c = 0xFFFF
        out[46] = ((c shr 8) and 0xFF).toByte()
        out[47] = (c and 0xFF).toByte()
        return out
    }

    /// 写 UDP 头（源/目的端口、长度），校验和由调用方按 IP 版本填充
    private fun writeUdpHeaderAndPayload(
        out: ByteArray, udpStart: Int, srcPort: Int, dstPort: Int, payload: ByteArray
    ) {
        out[udpStart] = (srcPort shr 8).toByte()
        out[udpStart + 1] = srcPort.toByte()
        out[udpStart + 2] = (dstPort shr 8).toByte()
        out[udpStart + 3] = dstPort.toByte()
        val udpLen = 8 + payload.size
        out[udpStart + 4] = (udpLen shr 8).toByte()
        out[udpStart + 5] = udpLen.toByte()
        out[udpStart + 6] = 0; out[udpStart + 7] = 0
        payload.copyInto(out, udpStart + 8)
    }

    private fun checksum(bytes: ByteArray, offset: Int, length: Int): Int {
        var sum = 0L
        var i = offset
        val end = offset + length
        while (i + 1 < end) {
            sum += ((bytes[i].toInt() and 0xFF) shl 8) or (bytes[i + 1].toInt() and 0xFF)
            i += 2
        }
        if (i < end) sum += (bytes[i].toInt() and 0xFF) shl 8
        while (sum shr 16 != 0L) sum = (sum and 0xFFFF) + (sum shr 16)
        return (sum.toInt().inv() and 0xFFFF)
    }

    private fun parseIp(b: ByteArray, off: Int): Int =
        ((b[off].toInt() and 0xFF) shl 24) or
        ((b[off + 1].toInt() and 0xFF) shl 16) or
        ((b[off + 2].toInt() and 0xFF) shl 8) or
        (b[off + 3].toInt() and 0xFF)

    private fun putIp(b: ByteArray, off: Int, ip: Int) {
        b[off] = ((ip shr 24) and 0xFF).toByte()
        b[off + 1] = ((ip shr 16) and 0xFF).toByte()
        b[off + 2] = ((ip shr 8) and 0xFF).toByte()
        b[off + 3] = (ip and 0xFF).toByte()
    }

    // ------------------------------------------------------------------
    // 统计持久化
    // ------------------------------------------------------------------

    private var lastPersist = 0L

    private fun persistStats() {
        val now = System.currentTimeMillis()
        if (now - lastPersist < 5000) return
        lastPersist = now
        try {
            getSharedPreferences("adshield_stats", MODE_PRIVATE).edit()
                .putLong("blocked_today", blockedCount.get())
                .putLong("allowed_today", allowedCount.get())
                .putLong("total_blocked", totalBlocked.get())
                .putLong("stats_date", now)
                .apply()
        } catch (_: Exception) { }
    }
}

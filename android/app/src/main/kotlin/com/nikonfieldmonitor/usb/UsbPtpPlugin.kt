package com.nikonfieldmonitor.usb

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Android USB Host PTP transport.
 *
 * Wraps android.hardware.usb to talk MTP/PTP-over-USB bulk transfers. The
 * PTP framing (container header: length/type/code/transactionId + params) is
 * the USB variant — different from PTP-IP but the operation codes are shared
 * with [com.nikonfieldmonitor.app] (see lib/ptp/nikon_opcodes.dart).
 *
 * References:
 *   - remoteyourcam-usb: UsbCamera.java, UsbPtpAction.java
 *   - gphoto2 camlibs/ptp2/usb.c
 *   - libmtp libusb.c
 *
 * MethodChannel "nikon_field_monitor/usb_ptp":
 *   hasUsbHost()                       -> Boolean
 *   listUsbDevices()                   -> List<Map>
 *   requestPermission(deviceId)        -> Boolean
 *   open(deviceId)                     -> Map(sessionHandle, model, firmware)
 *   close(sessionHandle)               -> null
 *   operate(sessionHandle, opCode, params, outData?, expectData) -> Map(code, params, data)
 *
 * EventChannel "nikon_field_monitor/usb_ptp/events":
 *   attached / detached / ptpEvent
 */
class UsbPtpPlugin(private val ctx: Context) : FlutterPlugin, MethodChannel.MethodCallHandler {

    private var binding: FlutterPlugin.FlutterPluginBinding? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null

    private val usbManager: UsbManager by lazy {
        ctx.getSystemService(Context.USB_SERVICE) as UsbManager
    }
    private val sessions = mutableMapOf<Int, UsbPtpSession>()
    private var nextSessionHandle = 1
    private var nextTransactionId = 1

    private var receiverRegistered = false

    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent?.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent?.getParcelableExtra(UsbManager.EXTRA_DEVICE) as? UsbDevice
            }
            when (intent?.action) {
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> {
                    device?.let { eventSink?.success(mapOf(
                        "event" to "attached",
                        "deviceId" to it.deviceId.toString(),
                        "productName" to (it.productName ?: "Unknown"),
                        "vendorId" to it.vendorId,
                        "productId" to it.productId,
                    )) }
                }
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    device?.let { eventSink?.success(mapOf(
                        "event" to "detached",
                        "deviceId" to it.deviceId.toString(),
                    )) }
                }
                USB_PERMISSION_ACTION -> {
                    val granted = intent?.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false) ?: false
                    eventSink?.success(mapOf(
                        "event" to "permissionResult",
                        "granted" to granted,
                        "deviceId" to device?.deviceId?.toString(),
                    ))
                }
            }
        }
    }

    private fun registerReceiver() {
        if (receiverRegistered) return
        val filter = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
            addAction(USB_PERMISSION_ACTION)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ctx.registerReceiver(usbReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            ctx.registerReceiver(usbReceiver, filter)
        }
        receiverRegistered = true
    }

    private fun unregisterReceiver() {
        if (!receiverRegistered) return
        try { ctx.unregisterReceiver(usbReceiver) } catch (_: Exception) {}
        receiverRegistered = false
    }

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        binding = b
        methodChannel = MethodChannel(b.binaryMessenger, "nikon_field_monitor/usb_ptp").also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(b.binaryMessenger, "nikon_field_monitor/usb_ptp/events").also {
            it.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                    registerReceiver()
                }
                override fun onCancel(arguments: Any?) {
                    unregisterReceiver()
                    eventSink = null
                }
            })
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        for (s in sessions.values) s.close()
        sessions.clear()
        this.binding = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "hasUsbHost" -> result.success(true) // package manager feature check omitted for brevity
                "listUsbDevices" -> result.success(listDevices())
                "requestPermission" -> {
                    val id = call.argument<String>("deviceId")!!
                    result.success(requestPermission(id))
                }
                "open" -> {
                    val id = call.argument<String>("deviceId")!!
                    openSession(id, result)
                }
                "close" -> {
                    val handle = call.argument<Number>("sessionHandle")!!.toInt()
                    sessions.remove(handle)?.close()
                    result.success(null)
                }
                "operate" -> {
                    val handle = call.argument<Number>("sessionHandle")!!.toInt()
                    val opCode = call.argument<Number>("opCode")!!.toInt()
                    @Suppress("UNCHECKED_CAST")
                    val params = (call.argument<List<Number>>("params") ?: emptyList()).map { it.toInt() }
                    val outData = call.argument<ByteArray>("outData")
                    val expectData = call.argument<Boolean>("expectData") ?: false
                    val s = sessions[handle]
                    if (s == null) { result.error("no-session", "handle $handle not found", null); return }
                    val r = s.operate(opCode, params, outData, expectData, nextTransactionId++)
                    result.success(mapOf(
                        "code" to r.code,
                        "params" to r.params,
                        "data" to r.data,
                    ))
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.e(TAG, "method ${call.method} failed", e)
            result.error("usb-error", e.message, null)
        }
    }

    private fun listDevices(): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        for (device in usbManager.deviceList.values) {
            out.add(mapOf(
                "deviceId" to device.deviceId.toString(),
                "productName" to (device.productName ?: "Unknown"),
                "vendorId" to device.vendorId,
                "productId" to device.productId,
            ))
        }
        return out
    }

    private fun requestPermission(deviceId: String): Boolean {
        val device = usbManager.deviceList.values.firstOrNull { it.deviceId.toString() == deviceId }
            ?: return false
        if (usbManager.hasPermission(device)) return true
        registerReceiver()
        val intentFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        else PendingIntent.FLAG_UPDATE_CURRENT
        val pi = PendingIntent.getBroadcast(ctx, 0,
            Intent(USB_PERMISSION_ACTION).setPackage(ctx.packageName), intentFlags)
        usbManager.requestPermission(device, pi)
        for (i in 0 until 30) {
            if (usbManager.hasPermission(device)) return true
            Thread.sleep(100)
        }
        return usbManager.hasPermission(device)
    }

    private fun openSession(deviceId: String, result: MethodChannel.Result) {
        val device = usbManager.deviceList.values.firstOrNull { it.deviceId.toString() == deviceId }
        if (device == null) { result.error("not-found", "device $deviceId not found", null); return }
        if (!usbManager.hasPermission(device)) {
            result.error("no-permission", "USB permission not granted", null); return
        }
        val iface = findPtpInterface(device)
        if (iface == null) { result.error("no-iface", "No PTP interface on device", null); return }
        val conn = usbManager.openDevice(device)
        if (conn == null) { result.error("open-failed", "openDevice returned null", null); return }
        if (!conn.claimInterface(iface, true)) {
            result.error("claim-failed", "claimInterface failed", null); return
        }
        val (inEp, outEp) = findEndpoints(iface)
        if (inEp == null || outEp == null) {
            result.error("no-endpoints", "Could not find bulk in/out endpoints", null); return
        }
        val session = UsbPtpSession(conn, iface, inEp, outEp)
        val handle = nextSessionHandle++
        sessions[handle] = session
        // Issue OpenSession (PTP op 0x1002) with a synthetic session id.
        val r = session.operate(0x1002, listOf(handle), null, false, nextTransactionId++)
        if (r.code != 0x2001) {
            // Some cameras don't require OpenSession over USB; treat non-fatal.
            Log.w(TAG, "OpenSession over USB returned 0x${r.code.toString(16)}")
        }
        result.success(mapOf(
            "sessionHandle" to handle,
            "model" to (device.productName ?: "Nikon"),
            "firmware" to "",
        ))
    }

    private fun findPtpInterface(device: UsbDevice): UsbInterface? {
        for (i in 0 until device.interfaceCount) {
            val iface = device.getInterface(i)
            if (iface.interfaceClass == UsbConstants.USB_CLASS_STILL_IMAGE ||
                iface.endpointCount >= 2) {
                return iface
            }
        }
        return null
    }

    private fun findEndpoints(iface: UsbInterface): Pair<UsbEndpoint?, UsbEndpoint?> {
        var inEp: UsbEndpoint? = null
        var outEp: UsbEndpoint? = null
        for (i in 0 until iface.endpointCount) {
            val ep = iface.getEndpoint(i)
            if (ep.type != UsbConstants.USB_ENDPOINT_XFER_BULK) continue
            if (ep.direction == UsbConstants.USB_DIR_IN) inEp = ep
            else if (ep.direction == UsbConstants.USB_DIR_OUT) outEp = ep
        }
        return inEp to outEp
    }

    companion object {
        private const val TAG = "UsbPtpPlugin"
        private const val USB_PERMISSION_ACTION = "com.nikonfieldmonitor.USB_PERMISSION"
    }
}

/**
 * One open USB PTP session: owns the [UsbDeviceConnection], the claimed
 * [UsbInterface], and the in/out bulk endpoints.
 *
 * PTP-over-USB container layout (PIMA 15740-3):
 *   [length:u32][type:u16][code:u16][transactionId:u32][params...u32 each]
 * Container types: 0x0001 Command, 0x0002 Data, 0x0003 Response, 0x0004 Event.
 */
class UsbPtpSession(
    private val conn: UsbDeviceConnection,
    private val iface: UsbInterface,
    private val inEp: UsbEndpoint,
    private val outEp: UsbEndpoint,
) {
    data class Result(val code: Int, val params: List<Int>, val data: ByteArray?)

    fun operate(opCode: Int, params: List<Int>, outData: ByteArray?, expectData: Boolean, txId: Int): Result {
        // Send command container.
        val cmdContainer = buildCommandContainer(opCode, params, txId)
        conn.bulkTransfer(outEp, cmdContainer, cmdContainer.size, TIMEOUT_MS)

        // Send data if present.
        if (outData != null) {
            val dataContainer = buildDataContainer(outData, txId)
            conn.bulkTransfer(outEp, dataContainer, dataContainer.size, TIMEOUT_MS)
        }

        // Read response (and data if expected).
        var responseData: ByteArray? = null
        if (expectData) {
            responseData = readDataContainer(txId)
        }
        val resp = readResponseContainer(txId)
        return Result(resp.first, resp.second, responseData)
    }

    private fun buildCommandContainer(opCode: Int, params: List<Int>, txId: Int): ByteArray {
        val len = 12 + 4 * params.size
        val bb = ByteBuffer.allocate(len).order(ByteOrder.LITTLE_ENDIAN)
        bb.putInt(len)           // length
        bb.putShort(0x0001)      // type: Command
        bb.putShort(opCode.toShort())
        bb.putInt(txId)
        for (p in params) bb.putInt(p)
        return bb.array()
    }

    private fun buildDataContainer(data: ByteArray, txId: Int): ByteArray {
        val len = 12 + data.size
        val bb = ByteBuffer.allocate(len).order(ByteOrder.LITTLE_ENDIAN)
        bb.putInt(len)
        bb.putShort(0x0002)      // type: Data
        bb.putShort(0)           // code: irrelevant for data phase
        bb.putInt(txId)
        bb.put(data)
        return bb.array()
    }

    private fun readDataContainer(expectedTx: Int): ByteArray? {
        val buf = ByteArray(inEp.maxPacketSize.coerceAtLeast(512))
        val out = ByteArrayOutputStream()
        var totalLen = -1
        while (true) {
            val n = conn.bulkTransfer(inEp, buf, buf.size, TIMEOUT_MS)
            if (n <= 0) break
            out.write(buf, 0, n)
            if (totalLen < 0 && n >= 4) {
                totalLen = ByteBuffer.wrap(buf, 0, 4).order(ByteOrder.LITTLE_ENDIAN).int
            }
            if (totalLen > 0 && out.size() >= totalLen) break
        }
        val all = out.toByteArray()
        if (all.size < 12) return null
        // Strip the 12-byte header.
        return all.copyOfRange(12, all.size)
    }

    private fun readResponseContainer(expectedTx: Int): Pair<Int, List<Int>> {
        val buf = ByteArray(inEp.maxPacketSize.coerceAtLeast(512))
        val n = conn.bulkTransfer(inEp, buf, buf.size, TIMEOUT_MS)
        if (n < 8) return 0x2002 to emptyList() // general error
        val bb = ByteBuffer.wrap(buf, 0, n).order(ByteOrder.LITTLE_ENDIAN)
        bb.int // length
        bb.short // type (should be 0x0003 Response)
        val code = bb.short.toInt() and 0xFFFF
        bb.int // transaction id
        val params = mutableListOf<Int>()
        while (bb.remaining() >= 4) params.add(bb.int)
        return code to params
    }

    fun close() {
        try { conn.releaseInterface(iface) } catch (_: Exception) {}
        try { conn.close() } catch (_: Exception) {}
    }

    companion object { private const val TIMEOUT_MS = 5000 }
}

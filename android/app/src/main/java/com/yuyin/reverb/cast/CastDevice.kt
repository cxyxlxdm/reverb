package com.yuyin.reverb.cast

/**
 * 一个可以投放的 UPnP 媒体渲染器(电视 / 音箱 / 盒子)。
 *
 * [controlUrl] 是设备描述里 AVTransport 服务的 control URL —— SOAP 请求都发给它。
 * 没有任何三方 SDK:发现走 SSDP,控制走标准 AVTransport 动作(见 `DlnaClient`)。
 */
data class CastDevice(
    val id: String,
    val name: String,
    val model: String,
    val location: String,
    val controlUrl: String
)

package com.yuyin.reverb.data.local

import android.content.Context

/** 持久化用户自定义的发现页分类顺序（仅存标签顺序）。 */
class CategoryStore(context: Context) {
    private val prefs = context.getSharedPreferences("reverb_prefs", Context.MODE_PRIVATE)

    fun loadOrder(): List<String> {
        val raw = prefs.getString(KEY, null) ?: return emptyList()
        return raw.split(SEP).filter { it.isNotBlank() }
    }

    fun saveOrder(labels: List<String>) {
        prefs.edit().putString(KEY, labels.joinToString(SEP)).apply()
    }

    private companion object {
        const val KEY = "category_order"
        const val SEP = ""
    }
}

# -*- coding: utf-8 -*-
"""
Tests for fundamental adapter helpers.
"""

import os
import sys
import unittest
from datetime import datetime, timedelta
from unittest.mock import patch

import pandas as pd

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from data_provider.fundamental_adapter import (
    AkshareFundamentalAdapter,
    _build_dividend_payload,
    _extract_latest_row,
    _parse_dividend_plan_to_per_share,
    _ths_market_id,
)


class _FakeResponse:
    def __init__(self, payload, status_code=200):
        self._payload = payload
        self.status_code = status_code

    def raise_for_status(self) -> None:
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")

    def json(self):
        return self._payload


def _ths_funds_payload(stock_code="600667"):
    return {
        "status_code": 0,
        "status_msg": "",
        "data": {
            "code": stock_code,
            "marketId": "17",
            "fundsData": {
                "largeOrderFlow": {
                    "big_capital_inflow": 884_545_880,
                    "big_capital_outflow": 1_027_794_530,
                    "big_capital_net_inflow": -143_248_650,
                    "mass_capital_inflow": 832_118_460,
                    "mass_capital_outflow": 1_044_111_710,
                    "mass_capital_net_inflow": -211_993_250,
                    "medium_capital_net_inflow": 117_317_630,
                    "small_capital_net_inflow": 237_924_270,
                }
            },
        },
    }


class TestFundamentalAdapter(unittest.TestCase):
    def test_parse_dividend_plan_to_per_share_supports_cn_patterns(self) -> None:
        self.assertAlmostEqual(_parse_dividend_plan_to_per_share("10派3元(含税)"), 0.3, places=6)
        self.assertAlmostEqual(_parse_dividend_plan_to_per_share("每10股派发2.5元"), 0.25, places=6)
        self.assertAlmostEqual(_parse_dividend_plan_to_per_share("每股派0.8元"), 0.8, places=6)
        self.assertIsNone(_parse_dividend_plan_to_per_share("仅送股，不现金分红"))

    def test_extract_latest_row_returns_none_when_code_mismatch(self) -> None:
        df = pd.DataFrame(
            {
                "股票代码": ["600000", "000001"],
                "值": [1, 2],
            }
        )
        row = _extract_latest_row(df, "600519")
        self.assertIsNone(row)

    def test_extract_latest_row_fallback_when_no_code_column(self) -> None:
        df = pd.DataFrame({"值": [1, 2]})
        row = _extract_latest_row(df, "600519")
        self.assertIsNotNone(row)
        self.assertEqual(row["值"], 1)

    def test_ths_market_id_covers_shenzhen_shanghai_and_beijing(self) -> None:
        self.assertEqual(_ths_market_id("000001"), "33")
        self.assertEqual(_ths_market_id("300750.SZ"), "33")
        self.assertEqual(_ths_market_id("600667"), "17")
        self.assertEqual(_ths_market_id("688981.SH"), "17")
        self.assertEqual(_ths_market_id("838163"), "145")
        self.assertEqual(_ths_market_id("920748.BJ"), "151")

    def test_ths_stock_flow_normalizes_main_force_net_inflow_and_caches(self) -> None:
        adapter = AkshareFundamentalAdapter()
        with patch(
            "data_provider.fundamental_adapter.requests.get",
            return_value=_FakeResponse(_ths_funds_payload()),
        ) as request_get:
            first, first_error = adapter._get_ths_stock_flow("600667")
            second, second_error = adapter._get_ths_stock_flow("600667.SH")

        self.assertIsNone(first_error)
        self.assertIsNone(second_error)
        self.assertEqual(first, second)
        self.assertEqual(first["main_net_inflow"], -355_241_900.0)
        self.assertIsNone(first["inflow_5d"])
        self.assertIsNone(first["inflow_10d"])
        self.assertEqual(request_get.call_count, 1)
        self.assertEqual(request_get.call_args.kwargs["params"], {"code": "600667", "marketId": "17"})
        self.assertEqual(request_get.call_args.kwargs["timeout"], 2.0)

    def test_capital_flow_uses_ths_without_waiting_for_eastmoney(self) -> None:
        adapter = AkshareFundamentalAdapter()
        stock_flow = {
            "main_net_inflow": 12_500_000.0,
            "inflow_5d": None,
            "inflow_10d": None,
        }
        with patch.object(adapter, "_get_ths_stock_flow", return_value=(stock_flow, None)), \
                patch.object(adapter, "_call_df_candidates") as call_candidates:
            result = adapter.get_capital_flow("600667")

        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["stock_flow"], stock_flow)
        self.assertEqual(result["source_chain"], ["capital_stock:stockpage_ths"])
        call_candidates.assert_not_called()

    def test_capital_flow_falls_back_to_eastmoney_when_ths_fails(self) -> None:
        adapter = AkshareFundamentalAdapter()
        stock_df = pd.DataFrame(
            {
                "股票代码": ["600667"],
                "主力净流入-净额": [1_500_000.0],
                "5日主力净流入-净额": [8_000_000.0],
                "10日主力净流入-净额": [15_000_000.0],
            }
        )
        with patch.object(
            adapter,
            "_get_ths_stock_flow",
            return_value=({}, "stockpage_ths:Timeout"),
        ), patch.object(
            adapter,
            "_call_df_candidates",
            side_effect=[
                (stock_df, "stock_individual_fund_flow", []),
                (None, None, []),
            ],
        ):
            result = adapter.get_capital_flow("600667")

        self.assertEqual(result["stock_flow"]["main_net_inflow"], 1_500_000.0)
        self.assertIn("capital_stock:stock_individual_fund_flow", result["source_chain"])
        self.assertIn("stockpage_ths:Timeout", result["errors"])

    def test_dragon_tiger_no_match_with_code_column_is_ok(self) -> None:
        adapter = AkshareFundamentalAdapter()
        df = pd.DataFrame(
            {
                "股票代码": ["600000"],
                "日期": ["2026-01-01"],
            }
        )
        with patch.object(adapter, "_call_df_candidates", return_value=(df, "stock_lhb_stock_statistic_em", [])):
            result = adapter.get_dragon_tiger_flag("600519")
        self.assertEqual(result["status"], "ok")
        self.assertFalse(result["is_on_list"])
        self.assertEqual(result["recent_count"], 0)

    def test_dragon_tiger_match_is_ok(self) -> None:
        adapter = AkshareFundamentalAdapter()
        today = pd.Timestamp.now().strftime("%Y-%m-%d")
        df = pd.DataFrame(
            {
                "股票代码": ["600519"],
                "日期": [today],
            }
        )
        with patch.object(adapter, "_call_df_candidates", return_value=(df, "stock_lhb_stock_statistic_em", [])):
            result = adapter.get_dragon_tiger_flag("600519")
        self.assertEqual(result["status"], "ok")
        self.assertTrue(result["is_on_list"])
        self.assertGreaterEqual(result["recent_count"], 1)

    def test_fundamental_bundle_includes_financial_report_and_dividend_payload(self) -> None:
        adapter = AkshareFundamentalAdapter()
        now = datetime.now()
        within_ttm = (now - timedelta(days=30)).strftime("%Y-%m-%d")
        future_day = (now + timedelta(days=10)).strftime("%Y-%m-%d")
        old_day = (now - timedelta(days=500)).strftime("%Y-%m-%d")
        fin_df = pd.DataFrame(
            {
                "股票代码": ["600519"],
                "报告期": [within_ttm],
                "营业总收入": [1000.0],
                "归母净利润": [300.0],
                "经营活动产生的现金流量净额": [500.0],
                "净资产收益率": [18.2],
                "营业收入同比": [12.0],
                "净利润同比": [9.5],
            }
        )
        forecast_df = pd.DataFrame({"股票代码": ["600519"], "预告": ["预增"]})
        quick_df = pd.DataFrame({"股票代码": ["600519"], "快报": ["快报摘要"]})
        dividend_df = pd.DataFrame(
            {
                "股票代码": ["600519", "600519", "600519", "600519"],
                "除息日": [within_ttm, within_ttm, future_day, old_day],
                "分配方案": ["10派3元(含税)", "10派3元(含税)", "10派5元", "10派1元"],
            }
        )

        with patch.object(
            adapter,
            "_call_df_candidates",
            side_effect=[
                (fin_df, "stock_financial_abstract", []),
                (forecast_df, "stock_yjyg_em", []),
                (quick_df, "stock_yjkb_em", []),
                (dividend_df, "stock_fhps_detail_em", []),
                (None, None, []),
                (None, None, []),
            ],
        ):
            result = adapter.get_fundamental_bundle("600519")

        financial_report = result["earnings"].get("financial_report", {})
        self.assertEqual(financial_report.get("report_date"), within_ttm)
        self.assertEqual(financial_report.get("revenue"), 1000.0)
        self.assertEqual(financial_report.get("net_profit_parent"), 300.0)
        self.assertEqual(financial_report.get("operating_cash_flow"), 500.0)
        self.assertEqual(financial_report.get("roe"), 18.2)

        dividend_payload = result["earnings"].get("dividend", {})
        events = dividend_payload.get("events", [])
        self.assertEqual(len(events), 2)  # duplicate + future day filtered
        self.assertEqual(dividend_payload.get("ttm_event_count"), 1)
        self.assertAlmostEqual(dividend_payload.get("ttm_cash_dividend_per_share"), 0.3, places=6)

    def test_build_dividend_payload_returns_empty_when_code_not_matched(self) -> None:
        now = datetime.now().strftime("%Y-%m-%d")
        df = pd.DataFrame(
            {
                "股票代码": ["000001"],
                "除息日": [now],
                "分配方案": ["10派3元(含税)"],
            }
        )

        payload = _build_dividend_payload(df, stock_code="600519")
        self.assertEqual(payload, {})

    def test_build_dividend_payload_skips_after_tax_plan(self) -> None:
        now = datetime.now().strftime("%Y-%m-%d")
        df = pd.DataFrame(
            {
                "股票代码": ["600519"],
                "除息日": [now],
                "分配方案": ["10派3元(税后)"],
            }
        )

        payload = _build_dividend_payload(df, stock_code="600519")
        self.assertEqual(payload, {})

    def test_build_dividend_payload_ttm_window_boundary(self) -> None:
        now = datetime.now()
        day_365 = (now - timedelta(days=365)).strftime("%Y-%m-%d")
        day_366 = (now - timedelta(days=366)).strftime("%Y-%m-%d")
        df = pd.DataFrame(
            {
                "股票代码": ["600519", "600519"],
                "除息日": [day_365, day_366],
                "分配方案": ["10派3元(含税)", "10派5元(含税)"],
            }
        )

        payload = _build_dividend_payload(df, stock_code="600519")
        self.assertEqual(payload.get("ttm_event_count"), 1)
        self.assertAlmostEqual(payload.get("ttm_cash_dividend_per_share"), 0.3, places=6)


if __name__ == "__main__":
    unittest.main()

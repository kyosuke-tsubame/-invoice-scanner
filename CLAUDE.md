# 納品書スキャナー プロジェクト

## このプロジェクトについて
ラーメン店5店舗向けの納品書OCRアプリ。
納品書の写真を撮ってデータ化し、Googleスプレッドシートに自動記録する。

詳細は invoice-scanner-handoff.md を参照。

## 対象店舗
本店 / KADODE店 / 空港店 / 静岡紺屋町店 / セントラル

## 技術構成
- index.html 1枚（GitHub Pages で公開）
- OCR：Google Cloud Vision API
- データ保存：Googleスプレッドシート（DBとして使用）

## 現在の状況
- OCR読み取りまで実装済み
- 未実装：店舗選択UI・Sheets連携・確認画面・CSV廃止

## 次にやること
1. Google Cloud Vision API の課金設定（ユーザー作業）
2. 店舗選択UIの追加
3. Google Sheets API連携の実装
4. 保存前確認画面の実装
5. GitHub Pagesへデプロイ

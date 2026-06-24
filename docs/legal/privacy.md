# Privacy Policy

**Application:** Oxygen ("the App")
**Provider:** Titanium Intelligence, Inc. ("we", "us", "the Provider")
**Contact:** robert@oxygen-hq.com
**Effective date:** June 23, 2026

## 1. Overview

Oxygen is a private, operator-run data-entry application for Android. It
lets an operator record transactions (for example, inventory movements or
activity logs) and synchronize them to data services that the operator
controls — including Google Sheets, an on-device local ledger, and
QuickBooks Online. The App is used by the operator (and any staff the
operator authorizes) to manage the operator's own records. It is **not** a
public, consumer-facing service and does not host accounts for third-party
end users.

This policy explains what data the App handles, where it is stored, and
which third-party services it connects to.

## 2. Information the App handles

The App handles only the data needed to do its job:

- **Records you enter.** The contents of the transactions you log — for
  example item names/SKUs, quantities, dates, times, and notes. You choose
  what fields exist via the App's schema configuration.
- **Connection credentials.** Service-account keys and OAuth tokens
  (Google, QuickBooks Online) and API keys, used solely to access the
  accounts you have connected. These are stored on the device and/or
  bundled in the App build you install.
- **QuickBooks Online data.** When you enable the QuickBooks integration,
  the App reads inventory item details (such as item name, current
  quantity on hand, and the record's sync token) and writes inventory
  quantity adjustments, on your instruction (the "Update" action).

The App does **not** collect advertising identifiers, location, contacts,
or device analytics, and contains no third-party tracking or advertising
SDKs.

## 3. How information is used

Information is used only to provide the App's core function: to record your
transactions and synchronize them to the services you have connected. The
QuickBooks integration is used solely to keep inventory quantities in your
QuickBooks Online company in sync with the transactions you record. We do
not use your data for advertising, profiling, or resale.

## 4. Where information is stored

- **On your device.** Transactions, a local push-status ledger, and the
  connection tokens are stored in local databases and preferences on the
  Android device running the App.
- **In your data services.** Depending on your configuration, transactions
  are written to your Google Sheets and/or kept in the on-device ledger.
- **In your QuickBooks Online company.** Inventory quantity adjustments you
  push are written to the QuickBooks Online company you authorized.

The Provider does not operate a central server and does not receive or
retain a copy of your data on its own infrastructure.

## 5. Third-party services

The App communicates directly with the following services, each governed by
its own privacy policy, and only to the extent you configure:

- **Intuit / QuickBooks Online** — to read inventory items and write
  quantity adjustments. See Intuit's privacy policy at
  https://www.intuit.com/privacy/.
- **Google (Google Sheets API)** — to read and write your spreadsheet
  records. See https://policies.google.com/privacy.
- **GitHub** (optional) — to fetch schema/configuration updates. See
  https://docs.github.com/site-policy.
- **Anthropic and/or OpenAI** (optional AI features) — if you enable the
  optional assistant or post-entry hooks, the relevant entry/context text
  is sent to the configured model provider to generate a response. Disable
  these features to prevent any such transmission.

We share data with these services only as needed to perform the action you
requested, and we do not sell data to anyone.

## 6. QuickBooks Online specifics

- The App accesses your QuickBooks Online data only after you explicitly
  authorize it via Intuit's OAuth flow.
- Access and refresh tokens are stored locally on the device and used only
  to maintain your authorized connection. Refresh tokens rotate per
  Intuit's policy and the latest value replaces the prior one.
- You can revoke the App's access at any time from your Intuit account
  (Settings → Connected apps) or by contacting us; revocation immediately
  stops the App's ability to read or write your QuickBooks data.
- The App's use of information received from QuickBooks APIs adheres to
  Intuit's developer requirements and is limited to the inventory-sync
  purpose described above.

## 7. Security

All connections to third-party services use encrypted HTTPS/TLS.
Credentials and tokens are stored on the operator's device. Because the App
is operator-run with no central server, you are responsible for the
physical and account security of the device(s) running the App.

## 8. Data retention and deletion

- Local data persists on the device until you delete it or uninstall the
  App. Uninstalling removes the App's local databases, including stored
  tokens.
- Data written to Google Sheets or QuickBooks Online is retained according
  to your settings in those services; manage or delete it there.
- To disconnect QuickBooks, revoke access in your Intuit account as
  described in Section 6.

## 9. Children

The App is a business/productivity tool and is not directed to children
under 13 (or the equivalent minimum age in your jurisdiction).

## 10. Changes to this policy

We may update this policy from time to time. Material changes will be
reflected by updating the effective date above and publishing the revised
policy at its hosted URL.

## 11. Contact

Questions about this policy:

Titanium Intelligence, Inc.
3 E 3rd St., San Mateo, CA 94401, USA
robert@oxygen-hq.com

This policy is governed by the laws of the State of California, USA.

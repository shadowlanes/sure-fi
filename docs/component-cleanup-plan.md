# Component Cleanup Plan

## Context

Sure-Fi is forked from a full-featured open-source personal finance SaaS. The personal use case is narrower:
- Import bank statements (PDF) from multiple banks/currencies (UAE, India, etc.)
- Connect Indian mutual funds
- Connect IBKR (Interactive Brokers) trading profile
- Track expenses across multiple currencies

Most of the SaaS infrastructure and bank aggregation providers are unnecessary weight.

---

## Components to Strip

### 1. Plaid Integration (~50+ files)
**Reason:** US/EU bank aggregation service. User banks with ENBD (UAE) and uses PDF import. Indian mutual funds and IBKR won't come through Plaid.
**Files:** `app/models/plaid_item.rb`, `app/models/plaid_account.rb`, `app/models/plaid_account/`, `app/models/plaid_entry/`, `app/models/provider/plaid.rb`, `app/models/provider/plaid_adapter.rb`, `app/models/provider/plaid_eu_adapter.rb`, `app/models/provider/plaid_sandbox.rb`, `app/controllers/plaid_items_controller.rb`, `config/initializers/plaid_config.rb`, webhook routes for plaid/plaid_eu

### 2. SimpleFIN Integration (~20+ files)
**Reason:** Alternative US bank aggregation. Same reasoning as Plaid.
**Files:** `app/models/simplefin_item.rb`, `app/models/simplefin_account.rb`, `app/models/simplefin_account/`, `app/models/simplefin_entry/`, `app/models/provider/simplefin.rb`, `app/models/provider/simplefin_adapter.rb`, `app/controllers/simplefin_items_controller.rb`, `config/initializers/simplefin.rb`

### 3. Enable Banking / Open Banking (~10+ files)
**Reason:** EU PSD2 open banking. User is in UAE, not EU.
**Files:** `app/models/enable_banking_item.rb`, `app/models/enable_banking_account.rb`, `app/models/enable_banking_account/`, `app/models/enable_banking_entry/`, `app/models/provider/enable_banking.rb`, `app/models/provider/enable_banking_adapter.rb`, `app/controllers/enable_banking_items_controller.rb`

### 4. Lunchflow Integration (~10+ files)
**Reason:** Alternative aggregation service, not needed with PDF imports + direct IBKR/MF integrations.
**Files:** `app/models/lunchflow_item.rb`, `app/models/lunchflow_account.rb`, `app/models/lunchflow_account/`, `app/models/lunchflow_entry/`, `app/models/provider/lunchflow.rb`, `app/models/provider/lunchflow_adapter.rb`, `app/controllers/lunchflow_items_controller.rb`

### 5. CoinStats / Crypto (~5+ files)
**Reason:** No crypto in the use case.
**Files:** `app/models/coinstats_item.rb`, `app/models/coinstats_account.rb`, `app/models/coinstats_item/`, `app/models/provider/coinstats.rb`, `app/models/provider/coinstats_adapter.rb`, `app/controllers/coinstats_items_controller.rb`, `app/models/crypto.rb`

### 6. Stripe Billing / Subscriptions
**Reason:** Personal self-hosted instance, not a SaaS. No subscription management needed.
**Files:** `app/models/provider/stripe.rb`, `app/models/provider/stripe/`, `app/models/subscription.rb`, `app/controllers/settings/billings_controller.rb`, Stripe webhook routes, `app/controllers/subscriptions_controller.rb`

### 7. Invitation & Invite Code System
**Reason:** Personal use, no multi-user onboarding gates.
**Files:** `app/models/invitation.rb`, `app/models/invite_code.rb`, `app/controllers/invitations_controller.rb`, `app/controllers/invite_codes_controller.rb`

### 8. SSO / OIDC / Multi-provider Auth
**Reason:** Personal instance with local login. No enterprise SSO needed.
**Files:** `app/models/sso_provider.rb`, `app/models/sso_provider_tester.rb`, `app/models/sso_audit_log.rb`, `app/controllers/admin/sso_providers_controller.rb`, `app/controllers/oidc_accounts_controller.rb`, OmniAuth configuration

### 9. Impersonation System
**Reason:** Single-user/personal use. No support staff.
**Files:** `app/models/impersonation_session.rb`, `app/controllers/impersonation_sessions_controller.rb`

### 10. Property & Vehicle Account Types
**Reason:** Use case is bank accounts, mutual funds, and trading. No real estate or vehicle tracking.
**Files:** `app/models/property.rb`, `app/models/vehicle.rb`, related views/controllers

### 11. Demo Data Generator
**Reason:** Not needed for production personal use.
**Files:** `app/models/demo/generator.rb`, `app/models/demo/`, rake tasks

### 12. Mobile Device / OAuth App System
**Reason:** Personal web-only use. No mobile app.
**Files:** `app/models/mobile_device.rb`, related controllers

### 13. Doorkeeper OAuth2 (External API)
**Reason:** No third-party apps need API access. Keep simple API key auth if needed.
**Files:** Doorkeeper initializer, OAuth routes, token management

### 14. GitHub Provider (Changelog)
**Reason:** Displaying release notes from upstream repo not relevant for personal fork.
**Files:** `app/models/provider/github.rb`, changelog controller/views

---

## Components to Keep

### Core Financial Engine
- Account model + Depository, Investment, CreditCard, Loan, OtherAsset, OtherLiability
- Entry / Transaction / Trade / Valuation models
- Balance tracking and materialization
- Holdings and Securities system
- Exchange rate system (multi-currency is critical)
- Category, Tag, Merchant models

### Import System
- **StatementImport (PDF)** -- primary data ingestion
- **TransactionImport (CSV)** -- backup/alternative
- **TradeImport** -- for IBKR data
- AccountImport, CategoryImport -- setup helpers

### AI / LLM Integration
- OpenAI provider (via Gemini) -- powers PDF parsing
- Auto-categorization -- useful for imported transactions
- Chat assistant -- financial insights

### Reporting & Analytics
- Balance sheet, Income statement
- Budget module
- Recurring transaction detection
- Transfer matching
- Data export

### Rules Engine
- Auto-categorization rules
- Tag assignment rules

### Market Data Providers
- Yahoo Finance (free, no config) -- security prices
- Twelve Data (optional) -- exchange rates, security prices

### Auth (Simplified)
- Local email/password auth
- Session management
- Basic API key auth

### Settings
- User preferences (language, date format, timezone)
- Profile management
- Provider configuration (market data + LLM)

---

## Estimated Impact

- ~100+ model files removable
- ~20+ controller files removable
- Significant route simplification
- Fewer background jobs and scheduled tasks
- Simpler Provider::Registry
- Removal of all webhook endpoints
- Fewer gems (plaid, stripe, omniauth-*, doorkeeper)

## Execution Strategy

Do this in phases, largest/most isolated first:
1. **Phase 1:** Plaid (biggest, most self-contained)
2. **Phase 2:** SimpleFIN + Enable Banking + Lunchflow + CoinStats (all aggregation providers)
3. **Phase 3:** Stripe + Subscriptions + Invitations (SaaS infrastructure)
4. **Phase 4:** SSO/OIDC + Impersonation + Doorkeeper (auth simplification)
5. **Phase 5:** Property/Vehicle + Demo + Mobile + GitHub (small cleanups)

Each phase should be a separate branch with passing tests before merging.

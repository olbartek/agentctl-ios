# Agent commands

> **GENERATED** by `./appctl docs` from the `+Agent.swift` files. Do not edit by hand; run `./appctl docs` instead.

Every screen of AgentShop can be driven with the same commands headlessly (`./appctl run "…"`),
in scenario files (`scenarios/*.appctl`), at launch (`-appctl-seed`) and in the running app (`./appctl app run "…"`).

## Script syntax

- Commands are separated by `;` or newlines. `#` starts a comment.
- A command's argument is the rest of the line: `<command> a value with spaces`.
- Double quotes protect `;` and `#`: `<command> "a;b#c"`. Inside quotes, `\"` is a quote.
- After each command the app settles and one step is printed:

  ```text
  > submit
    screen=home/orders orders=3 loading=false calls=auth.login,session.save,orders.fetchOrders
  ```

  The line holds `screen`, the screen's summary keys, `calls=` (mock calls made during the step),
  `error=` (if set) and `pending=` (effects waiting on the clock, e.g. a countdown; headlessly
  `advance <duration>` releases them).
- Exit codes: `0` all steps passed, `1` a command or `expect` failed, `2` usage or parse error, `3` internal error.

## Examples

```bash
./appctl run "login-as alice; open 1003; cancel"              # cancel a pending order
./appctl run "use-otp; email alice@example.com; send; advance 30s; resend"
./appctl run "mock orders.fetchOrders network; login-as alice; retry"
./appctl run --session .appctl/s.session "register"   # keep going from the same state next time
./appctl app launch --no-build --seed "login-as bob; tab profile"   # the real app, already there
```

Scenarios in `scenarios/*.appctl` use the same syntax plus `expect` lines; `./appctl test` runs them.

## Runtime commands (every screen)

| Command | Description |
|---|---|
| `expect k=v [k=v …]` | Assert on screen, any summary key, call=<client.method> (called during the previous step), error=<code\|none> or pending=<n>. A failed assertion fails the script. |
| `advance <duration>` | Advance the test clock, e.g. 500ms, 30s, 5m, 1h. Headless only. |
| `mock <client.method> <error>` | Make the next call to that method fail, e.g. mock orders.fetchOrders network. |

## Screens

### `launching`

Screen: `AppFeature`.

| Command | Description | From |
|---|---|---|
| `login-as <alice\|bob>` | Save a seeded account's session and go straight home. | AppFeature |
| `reset` | Restart from a fresh launch (keeps the saved session and the mock data). | AppFeature |
| `back` | Fails with 'nothing to go back to' when no screen is pushed. | AppFeature |

### `auth/login`

Screen: `Login`.
Summary keys: `email`, `keepSignedIn`, `revealed`, `canSubmit`, `loading`.

| Command | Description | From |
|---|---|---|
| `email <text>` | Set the email field. | Login |
| `password <text>` | Set the password field. | Login |
| `show-password <on\|off>` | Show or hide the password. | Login |
| `keep-signed-in <on\|off>` | Tick "Keep me signed in" (on by default). Off: the session is not restored on relaunch. | Login |
| `submit` | Log in with the email and password. *(disabled when canSubmit=false)* | Login |
| `google` | Sign in with Google (the mock signs in as becca@gmail.com). *(disabled when loading=true)* | Login |
| `use-otp` | Switch to login with a one-time code (keeps the email). | Login |
| `register` | Open registration ("Sign up here"). | Login |
| `forgot` | Open forgot password (keeps the email). | Login |
| `login-as <alice\|bob>` | Save a seeded account's session and go straight home. | AppFeature |
| `reset` | Restart from a fresh launch (keeps the saved session and the mock data). | AppFeature |
| `back` | Fails with 'nothing to go back to' when no screen is pushed. | AppFeature |

### `auth/otp/email`

Screen: `OTPLogin`.
Summary keys: `email`, `canSend`, `resendIn`, `attemptsLeft`, `canVerify`, `loading`.

| Command | Description | From |
|---|---|---|
| `email <text>` | Set the email field. | OTPLogin |
| `send` | Email a one-time code. *(disabled when canSend=false)* | OTPLogin |
| `back` | Go back to the previous screen. | AuthFlow |
| `login-as <alice\|bob>` | Save a seeded account's session and go straight home. | AppFeature |
| `reset` | Restart from a fresh launch (keeps the saved session and the mock data). | AppFeature |

### `auth/otp/code`

Screen: `OTPLogin`.
Summary keys: `email`, `canSend`, `resendIn`, `attemptsLeft`, `canVerify`, `loading`.

| Command | Description | From |
|---|---|---|
| `code <digits>` | Type the 6-digit code. | OTPLogin |
| `verify` | Verify the code and log in. *(disabled when canVerify=false)* | OTPLogin |
| `resend` | Send a new code (blocked while resendIn > 0). | OTPLogin |
| `back` | Go back to the previous screen. | AuthFlow |
| `login-as <alice\|bob>` | Save a seeded account's session and go straight home. | AppFeature |
| `reset` | Restart from a fresh launch (keeps the saved session and the mock data). | AppFeature |

### `auth/register`

Screen: `Register`.
Summary keys: `email`, `terms`, `revealed`, `issues`, `canSubmit`, `loading`.

| Command | Description | From |
|---|---|---|
| `name <text>` | Set the full name field. | Register |
| `email <text>` | Set the email field. | Register |
| `password <text>` | Set the password field. | Register |
| `confirm <text>` | Set the confirm-password field. | Register |
| `show-password <on\|off>` | Show or hide the password. | Register |
| `show-confirm <on\|off>` | Show or hide the confirm-password field. | Register |
| `terms <on\|off>` | Accept or decline the terms. | Register |
| `submit` | Create the account; a verification code is emailed (verify it next). *(disabled when canSubmit=false)* | Register |
| `google` | Sign up with Google (the mock signs in as becca@gmail.com). *(disabled when loading=true)* | Register |
| `back` | Go back to the previous screen. | AuthFlow |
| `login-as <alice\|bob>` | Save a seeded account's session and go straight home. | AppFeature |
| `reset` | Restart from a fresh launch (keeps the saved session and the mock data). | AppFeature |

### `auth/register/verify`

Screen: `VerifyEmail`.
Summary keys: `email`, `resendIn`, `canVerify`, `loading`.

| Command | Description | From |
|---|---|---|
| `code <digits>` | Type the 6-digit verification code. | VerifyEmail |
| `verify` | Verify the email and sign in ("Create Account"). *(disabled when canVerify=false)* | VerifyEmail |
| `resend` | Email a new code (blocked while resendIn > 0). | VerifyEmail |
| `back` | Go back to the previous screen. | AuthFlow |
| `login-as <alice\|bob>` | Save a seeded account's session and go straight home. | AppFeature |
| `reset` | Restart from a fresh launch (keeps the saved session and the mock data). | AppFeature |

### `auth/forgot/email`

Screen: `ForgotPassword`.
Summary keys: `email`, `canSend`, `revealed`, `issues`, `canSubmit`, `loading`.

| Command | Description | From |
|---|---|---|
| `email <text>` | Set the email field. | ForgotPassword |
| `send` | Request a reset code (always succeeds). *(disabled when canSend=false)* | ForgotPassword |
| `back` | Go back to the previous screen. | AuthFlow |
| `login-as <alice\|bob>` | Save a seeded account's session and go straight home. | AppFeature |
| `reset` | Restart from a fresh launch (keeps the saved session and the mock data). | AppFeature |

### `auth/forgot/reset`

Screen: `ForgotPassword`.
Summary keys: `email`, `canSend`, `revealed`, `issues`, `canSubmit`, `loading`.

| Command | Description | From |
|---|---|---|
| `code <digits>` | Type the 6-digit reset code. | ForgotPassword |
| `password <text>` | Set the new password. | ForgotPassword |
| `confirm <text>` | Confirm the new password. | ForgotPassword |
| `show-password <on\|off>` | Show or hide the new password. | ForgotPassword |
| `show-confirm <on\|off>` | Show or hide the confirm field. | ForgotPassword |
| `submit` | Reset the password. *(disabled when canSubmit=false)* | ForgotPassword |
| `back` | Go back to the previous screen. | AuthFlow |
| `login-as <alice\|bob>` | Save a seeded account's session and go straight home. | AppFeature |
| `reset` | Restart from a fresh launch (keeps the saved session and the mock data). | AppFeature |

### `auth/forgot/done`

Screen: `ForgotPassword`.
Summary keys: `email`, `canSend`, `revealed`, `issues`, `canSubmit`, `loading`.

| Command | Description | From |
|---|---|---|
| `to-login` | Go back to login with the email prefilled. | ForgotPassword |
| `back` | Go back to the previous screen. | AuthFlow |
| `login-as <alice\|bob>` | Save a seeded account's session and go straight home. | AppFeature |
| `reset` | Restart from a fresh launch (keeps the saved session and the mock data). | AppFeature |

### `home/orders`

Screen: `OrdersList`.
Summary keys: `orders`, `loading`, `statuses`.

| Command | Description | From |
|---|---|---|
| `open <id>` | Open an order, e.g. open 1003. | OrdersList |
| `refresh` | Pull to refresh. | OrdersList |
| `retry` | Retry after a failed load. *(disabled when error=none)* | OrdersList |
| `tab <orders\|profile>` | Switch tab. | HomeTabs |
| `login-as <alice\|bob>` | Save a seeded account's session and go straight home. | AppFeature |
| `reset` | Restart from a fresh launch (keeps the saved session and the mock data). | AppFeature |
| `back` | Fails with 'nothing to go back to' when no screen is pushed. | AppFeature |

### `home/orders/<id>`

Screen: `OrderDetail`.
Summary keys: `id`, `status`, `items`, `total`, `date`, `canCancel`, `loading`.

| Command | Description | From |
|---|---|---|
| `cancel` | Cancel the order (pending orders only). *(disabled when canCancel=false)* | OrderDetail |
| `retry` | Reload the order after an error. *(disabled when error=none)* | OrderDetail |
| `tab <orders\|profile>` | Switch tab. | HomeTabs |
| `back` | Go back to the previous screen. | HomeTabs |
| `login-as <alice\|bob>` | Save a seeded account's session and go straight home. | AppFeature |
| `reset` | Restart from a fresh launch (keeps the saved session and the mock data). | AppFeature |

### `home/profile`

Screen: `Profile`.
Summary keys: `name`, `email`, `alert`.

| Command | Description | From |
|---|---|---|
| `logout` | Ask to log out (shows a confirmation alert). | Profile |
| `confirm` | Confirm logging out in the alert. *(disabled when alert=none)* | Profile |
| `dismiss` | Dismiss the alert. *(disabled when alert=none)* | Profile |
| `tab <orders\|profile>` | Switch tab. | HomeTabs |
| `login-as <alice\|bob>` | Save a seeded account's session and go straight home. | AppFeature |
| `reset` | Restart from a fresh launch (keeps the saved session and the mock data). | AppFeature |
| `back` | Fails with 'nothing to go back to' when no screen is pushed. | AppFeature |

## Mockable methods

`mock <method> <error>` makes the next call to the method throw that error.

| Method | Errors |
|---|---|
| `auth.login` | `invalidCredentials`, `accountLocked`, `unknownEmail`, `invalidCode`, `codeExpired`, `resendNotAvailable`, `emailTaken`, `weakPassword`, `emailNotVerified`, `network` |
| `auth.sendOTP` | `invalidCredentials`, `accountLocked`, `unknownEmail`, `invalidCode`, `codeExpired`, `resendNotAvailable`, `emailTaken`, `weakPassword`, `emailNotVerified`, `network` |
| `auth.verifyOTP` | `invalidCredentials`, `accountLocked`, `unknownEmail`, `invalidCode`, `codeExpired`, `resendNotAvailable`, `emailTaken`, `weakPassword`, `emailNotVerified`, `network` |
| `auth.register` | `invalidCredentials`, `accountLocked`, `unknownEmail`, `invalidCode`, `codeExpired`, `resendNotAvailable`, `emailTaken`, `weakPassword`, `emailNotVerified`, `network` |
| `auth.verifyEmail` | `invalidCredentials`, `accountLocked`, `unknownEmail`, `invalidCode`, `codeExpired`, `resendNotAvailable`, `emailTaken`, `weakPassword`, `emailNotVerified`, `network` |
| `auth.resendVerification` | `invalidCredentials`, `accountLocked`, `unknownEmail`, `invalidCode`, `codeExpired`, `resendNotAvailable`, `emailTaken`, `weakPassword`, `emailNotVerified`, `network` |
| `auth.signInWithGoogle` | `invalidCredentials`, `accountLocked`, `unknownEmail`, `invalidCode`, `codeExpired`, `resendNotAvailable`, `emailTaken`, `weakPassword`, `emailNotVerified`, `network` |
| `auth.requestPasswordReset` | `invalidCredentials`, `accountLocked`, `unknownEmail`, `invalidCode`, `codeExpired`, `resendNotAvailable`, `emailTaken`, `weakPassword`, `emailNotVerified`, `network` |
| `auth.resetPassword` | `invalidCredentials`, `accountLocked`, `unknownEmail`, `invalidCode`, `codeExpired`, `resendNotAvailable`, `emailTaken`, `weakPassword`, `emailNotVerified`, `network` |
| `orders.fetchOrders` | `notFound`, `notCancellable`, `network`, `unauthorized` |
| `orders.fetchOrder` | `notFound`, `notCancellable`, `network`, `unauthorized` |
| `orders.cancelOrder` | `notFound`, `notCancellable`, `network`, `unauthorized` |

## Test accounts

| Account | Password | Notes |
|---|---|---|
| `alice@example.com` | `Passw0rd!` | 3 orders: #1001 delivered, #1002 shipped, #1003 pending |
| `bob@example.com` | `Hunter22x` | no orders |
| `locked@example.com` | any | always `accountLocked` |

The OTP code is always `123456` and the password-reset code is always `654321`.

@extends('layouts.app')

@section('title_full', $account ? 'Edytuj konto Meta Messenger & IG' : 'Dodaj konto Meta Messenger & IG')

@section('content')
<div class="section-heading">
    {{ $account ? 'Edytuj konto Meta Messenger & IG' : 'Dodaj konto Meta Messenger & IG' }}
</div>

<div class="container mm-container">
    <div class="row">
        <div class="col-xs-12 col-md-8 col-md-offset-2">
            @include('partials/flash_messages')

            @if($account && !$account->credentialsAreReadable())
                <div class="alert alert-danger">
                    <strong>Nie można odszyfrować zapisanych poświadczeń (APP_KEY uległ zmianie).</strong>
                    Wprowadź ponownie <code>App Secret</code> oraz <code>Page Access Token</code> i zapisz formularz.
                </div>
            @endif

            <form method="POST"
                  action="{{ $account ? route('metamessenger.update', $account->id) : route('metamessenger.store') }}"
                  class="form-horizontal">
                {{ csrf_field() }}
                @if($account)
                    {{ method_field('PUT') }}
                @endif

                <h4>1. Skrzynka FreeScout i Identyfikacja Kanału</h4>
                <hr class="mm-section-hr">

                <div class="form-group{{ $errors->has('name') ? ' has-error' : '' }}">
                    <label class="col-sm-4 control-label" for="mm_name">Nazwa kanału *</label>
                    <div class="col-sm-8">
                        <input type="text" id="mm_name" name="name" class="form-control" required maxlength="100"
                               value="{{ old('name', $account->name ?? '') }}"
                               placeholder="np. Kato Salsa Hub (Messenger & IG)">
                        @if($errors->has('name'))
                            <p class="help-block">{{ $errors->first('name') }}</p>
                        @endif
                    </div>
                </div>

                <div class="form-group{{ $errors->has('mailbox_choice') ? ' has-error' : '' }}">
                    <label class="col-sm-4 control-label" for="mm_mailbox_choice">Docelowa skrzynka FreeScout *</label>
                    <div class="col-sm-8">
                        @php
                            $selectedMailbox = old('mailbox_choice', $account ? (string) $account->mailbox_id : ($defaultMailboxId ?? '__create_new__'));
                        @endphp
                        <select id="mm_mailbox_choice" name="mailbox_choice" class="form-control" required>
                            <option value="__create_new__" {{ $selectedMailbox === '__create_new__' ? 'selected' : '' }}>
                                + Utwórz automatycznie nową dedykowaną skrzynkę na pulpicie
                            </option>
                            @foreach($mailboxes as $mb)
                                <option value="{{ $mb->id }}" {{ (string) $mb->id === (string) $selectedMailbox ? 'selected' : '' }}>
                                    {{ $mb->name }} ({{ $mb->email }})
                                </option>
                            @endforeach
                        </select>
                        <p class="help-block">Możesz skierować rozmowy z FB/IG do istniejącej skrzynki (np. Fundacja Kato Salsa Hub) albo utworzyć osobny kafelek na pulpicie.</p>
                        @if($errors->has('mailbox_choice'))
                            <p class="help-block">{{ $errors->first('mailbox_choice') }}</p>
                        @endif
                    </div>
                </div>

                <div class="form-group{{ $errors->has('new_mailbox_name') ? ' has-error' : '' }}" id="mm_new_mailbox_group">
                    <label class="col-sm-4 control-label" for="mm_new_mailbox_name">Nazwa nowej skrzynki (max 40 zn.)</label>
                    <div class="col-sm-8">
                        <input type="text" id="mm_new_mailbox_name" name="new_mailbox_name" class="form-control" maxlength="40"
                               value="{{ old('new_mailbox_name', '') }}"
                               placeholder="np. Kato Salsa Hub (FB & IG)">
                        <p class="help-block">Zostaw puste, aby użyć nazwy kanału powyżej.</p>
                        @if($errors->has('new_mailbox_name'))
                            <p class="help-block">{{ $errors->first('new_mailbox_name') }}</p>
                        @endif
                    </div>
                </div>

                <div class="form-group{{ $errors->has('page_id') ? ' has-error' : '' }}">
                    <label class="col-sm-4 control-label" for="mm_page_id">Facebook Page ID *</label>
                    <div class="col-sm-8">
                        <input type="text" id="mm_page_id" name="page_id" class="form-control" required maxlength="64"
                               value="{{ old('page_id', $account->page_id ?? '') }}"
                               placeholder="np. 104829384756102">
                        <p class="help-block">Numeryczne ID Fanpage'a z Meta Business Suite / Messenger API Settings.</p>
                        @if($errors->has('page_id'))
                            <p class="help-block">{{ $errors->first('page_id') }}</p>
                        @endif
                    </div>
                </div>

                <div class="form-group{{ $errors->has('ig_account_id') ? ' has-error' : '' }}">
                    <label class="col-sm-4 control-label" for="mm_ig_account_id">Instagram Business Account ID</label>
                    <div class="col-sm-8">
                        <input type="text" id="mm_ig_account_id" name="ig_account_id" class="form-control" maxlength="64"
                               value="{{ old('ig_account_id', $account->ig_account_id ?? '') }}"
                               placeholder="np. 17841400000000000 (opcjonalnie — wykrywane też przyciskiem Testuj połączenie)">
                        <p class="help-block">ID konta profesjonalnego Instagram połączonego z Fanpage'em (dla <code>object=instagram</code>).</p>
                        @if($errors->has('ig_account_id'))
                            <p class="help-block">{{ $errors->first('ig_account_id') }}</p>
                        @endif
                    </div>
                </div>

                <h4 class="mm-section-title">2. Poświadczenia Meta Graph API (Szyfrowane AES-256)</h4>
                <hr class="mm-section-hr">

                <div class="form-group{{ $errors->has('app_id') ? ' has-error' : '' }}">
                    <label class="col-sm-4 control-label" for="mm_app_id">Meta App ID</label>
                    <div class="col-sm-8">
                        <input type="text" id="mm_app_id" name="app_id" class="form-control" maxlength="64"
                               value="{{ old('app_id', $account->app_id ?? '') }}"
                               placeholder="np. 1234567890123456">
                        @if($errors->has('app_id'))
                            <p class="help-block">{{ $errors->first('app_id') }}</p>
                        @endif
                    </div>
                </div>

                <div class="form-group{{ $errors->has('app_secret') ? ' has-error' : '' }}">
                    <label class="col-sm-4 control-label" for="mm_app_secret">Meta App Secret {{ $account ? '' : '*' }}</label>
                    <div class="col-sm-8">
                        <input type="password" id="mm_app_secret" name="app_secret" class="form-control"
                               autocomplete="new-password"
                               @if(!$account) required @endif
                               placeholder="{{ $account ? '•••••••• (zostaw puste, aby zachować obecny zaszyfrowany sekret)' : 'Wklej App Secret z App Settings -> Basic' }}">
                        <p class="help-block">Używany do kryptograficznej weryfikacji nagłówka <code>X-Hub-Signature-256</code> (HMAC-SHA256 fail-closed). Nigdy nie wyświetlany po zapisie.</p>
                        @if($errors->has('app_secret'))
                            <p class="help-block">{{ $errors->first('app_secret') }}</p>
                        @endif
                    </div>
                </div>

                <div class="form-group{{ $errors->has('page_access_token') ? ' has-error' : '' }}">
                    <label class="col-sm-4 control-label" for="mm_page_access_token">Page Access Token {{ $account ? '' : '*' }}</label>
                    <div class="col-sm-8">
                        <input type="password" id="mm_page_access_token" name="page_access_token" class="form-control"
                               autocomplete="new-password"
                               @if(!$account) required @endif
                               placeholder="{{ $account ? '•••••••• (zostaw puste, aby zachować obecny zaszyfrowany token)' : 'Wklej bezterminowy Page Access Token (pages_messaging / instagram_manage_messages)' }}">
                        <p class="help-block">Szyfrowany w bazie kluczem <code>APP_KEY</code> przez Laravel <code>encrypt()</code>. Nigdy nie wyświetlany po zapisie.</p>
                        @if($errors->has('page_access_token'))
                            <p class="help-block">{{ $errors->first('page_access_token') }}</p>
                        @endif
                    </div>
                </div>

                <h4 class="mm-section-title">3. Konfiguracja Webhooka w Meta for Developers</h4>
                <hr class="mm-section-hr">

                <div class="form-group">
                    <label class="col-sm-4 control-label" for="mm_webhook_url">Webhook Callback URL</label>
                    <div class="col-sm-8">
                        <div class="input-group">
                            <input type="text" id="mm_webhook_url" class="form-control" readonly value="{{ $webhookUrl }}">
                            <span class="input-group-btn">
                                <button type="button" class="btn btn-default" id="mm_copy_webhook">Kopiuj</button>
                            </span>
                        </div>
                        <p class="help-block">Wklej ten sam URL w <strong>Messenger → Webhooks</strong> oraz <strong>Instagram → Webhooks</strong> (pole subskrypcji: <code>messages</code>, opcjonalnie <code>messaging_postbacks</code>).</p>
                    </div>
                </div>

                <div class="form-group{{ $errors->has('verify_token') ? ' has-error' : '' }}">
                    <label class="col-sm-4 control-label" for="mm_verify_token">Verify Token *</label>
                    <div class="col-sm-8">
                        <div class="input-group">
                            <input type="text" id="mm_verify_token" name="verify_token" class="form-control" readonly
                                   value="{{ old('verify_token', $account->verify_token ?? $generatedToken) }}">
                            <span class="input-group-btn">
                                <button type="button" class="btn btn-default" id="mm_copy_verify">Kopiuj</button>
                                <button type="button" class="btn btn-default" id="mm_regen_verify">Generuj nowy</button>
                            </span>
                        </div>
                        @if($errors->has('verify_token'))
                            <p class="help-block">{{ $errors->first('verify_token') }}</p>
                        @endif
                    </div>
                </div>

                <div class="form-group">
                    <div class="col-sm-8 col-sm-offset-4">
                        <div class="checkbox">
                            <label>
                                <input type="checkbox" name="active" value="1"
                                       {{ old('active', $account ? (int) $account->active : 1) ? 'checked' : '' }}>
                                Kanał aktywny (odbieraj webhooki i wysyłaj odpowiedzi z FreeScout)
                            </label>
                        </div>
                    </div>
                </div>

                <div class="form-group">
                    <div class="col-sm-8 col-sm-offset-4">
                        <button type="submit" class="btn btn-primary">
                            {{ $account ? 'Zapisz zmiany' : 'Utwórz i aktywuj kanał' }}
                        </button>
                        <a href="{{ route('metamessenger.index') }}" class="btn btn-default">Anuluj</a>
                    </div>
                </div>
            </form>
        </div>
    </div>
</div>

<script type="text/javascript" {!! \Helper::cspNonceAttr() !!}>
(function () {
    function randomHex(byteLen) {
        var arr = new Uint8Array(byteLen);
        window.crypto.getRandomValues(arr);
        return Array.from(arr, function (b) {
            return ('0' + b.toString(16)).slice(-2);
        }).join('');
    }

    function bindCopy(btnId, inputId) {
        var btn = document.getElementById(btnId);
        var input = document.getElementById(inputId);
        if (!btn || !input) {
            return;
        }
        btn.addEventListener('click', function () {
            input.select();
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(input.value);
            } else {
                document.execCommand('copy');
            }
            var prev = btn.textContent;
            btn.textContent = 'Skopiowano!';
            setTimeout(function () { btn.textContent = prev; }, 1600);
        });
    }

    function initMetaMessengerForm() {
        bindCopy('mm_copy_webhook', 'mm_webhook_url');
        bindCopy('mm_copy_verify', 'mm_verify_token');

        var regenBtn = document.getElementById('mm_regen_verify');
        var verifyInput = document.getElementById('mm_verify_token');
        if (regenBtn && verifyInput) {
            regenBtn.addEventListener('click', function () {
                verifyInput.value = randomHex(24);
            });
        }

        var mailboxSelect = document.getElementById('mm_mailbox_choice');
        var newMailboxGroup = document.getElementById('mm_new_mailbox_group');
        function syncNewMailboxVisibility() {
            if (!mailboxSelect || !newMailboxGroup) {
                return;
            }
            newMailboxGroup.style.display = (mailboxSelect.value === '__create_new__') ? '' : 'none';
        }
        if (mailboxSelect) {
            mailboxSelect.addEventListener('change', syncNewMailboxVisibility);
            syncNewMailboxVisibility();
        }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initMetaMessengerForm);
    } else {
        initMetaMessengerForm();
    }
})();
</script>
@endsection

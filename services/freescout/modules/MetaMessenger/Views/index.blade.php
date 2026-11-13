@extends('layouts.app')

@section('title_full', 'Meta Messenger & Instagram DM')

@section('content')
<div class="section-heading">
    Meta Messenger &amp; Instagram DM
    <div class="section-heading-actions">
        <a href="{{ route('metamessenger.create') }}" class="btn btn-primary">
            Dodaj konto Fanpage / IG
        </a>
    </div>
</div>

<div class="container mm-container">
    <div class="row">
        <div class="col-xs-12">
            @include('partials/flash_messages')

            @if(!$isHttps)
                <div class="alert alert-warning">
                    <strong>Uwaga (HTTPS):</strong> Bieżący <code>APP_URL</code> (<code>{{ config('app.url') }}</code>) nie zaczyna się od <code>https://</code>.
                    Meta Graph API wymaga publicznego adresu HTTPS z ważnym certyfikatem TLS dla adresu Webhook Callback URL.
                </div>
            @endif

            <div class="well well-sm">
                <strong>Wspólny Webhook Callback URL (dla obiektów <code>page</code> oraz <code>instagram</code> w Meta Developers):</strong>
                <div class="input-group">
                    <input type="text" id="mm_index_webhook_url" class="form-control input-sm" readonly value="{{ $webhookUrl }}">
                    <span class="input-group-btn">
                        <button type="button" class="btn btn-default btn-sm" id="mm_copy_index_webhook">Kopiuj URL</button>
                    </span>
                </div>
            </div>

            @if($accounts->isEmpty())
                <div class="alert alert-info">
                    Brak skonfigurowanych kanałów Facebook Messenger / Instagram DM. Kliknij <strong>Dodaj konto Fanpage / IG</strong>, aby podpiąć pierwszy Fanpage (np. Kato Salsa Hub).
                </div>
            @else
                <table class="table table-striped">
                    <thead>
                        <tr>
                            <th>Nazwa kanału</th>
                            <th>Facebook Page ID</th>
                            <th>Instagram Business ID</th>
                            <th>Skrzynka FreeScout</th>
                            <th>Status</th>
                            <th class="text-right">Akcje</th>
                        </tr>
                    </thead>
                    <tbody>
                        @foreach($accounts as $acc)
                            @php $status = $acc->getStatusLabel(); @endphp
                            <tr>
                                <td><strong>{{ $acc->name }}</strong></td>
                                <td><code>{{ $acc->page_id }}</code></td>
                                <td>
                                    @if($acc->ig_account_id)
                                        <code>{{ $acc->ig_account_id }}</code>
                                    @else
                                        <span class="text-muted">—</span>
                                    @endif
                                </td>
                                <td>{{ $acc->mailbox->name ?? '⚠ Brak skrzynki' }}</td>
                                <td>
                                    @if($status === 'active')
                                        <span class="mm-badge-ok">&#9679; Aktywne</span>
                                    @elseif($status === 'credentials_broken')
                                        <span class="mm-badge-err">&#9888; Błąd APP_KEY (zapisz token ponownie)</span>
                                    @elseif($status === 'mailbox_unlinked')
                                        <span class="mm-badge-err">&#9888; Usunięta skrzynka</span>
                                    @else
                                        <span class="mm-badge-off">&#9675; Wyłączone</span>
                                    @endif
                                </td>
                                <td class="text-right">
                                    <form method="POST" action="{{ route('metamessenger.test', $acc->id) }}" class="mm-inline-form">
                                        {{ csrf_field() }}
                                        <button type="submit" class="btn btn-default btn-xs">Testuj połączenie</button>
                                    </form>
                                    <a href="{{ route('metamessenger.edit', $acc->id) }}" class="btn btn-default btn-xs">Edytuj</a>
                                    <form method="POST" action="{{ route('metamessenger.destroy', $acc->id) }}" class="mm-inline-form mm-delete-form">
                                        {{ csrf_field() }}
                                        {{ method_field('DELETE') }}
                                        <button type="submit" class="btn btn-default btn-xs text-danger">Usuń</button>
                                    </form>
                                </td>
                            </tr>
                        @endforeach
                    </tbody>
                </table>
            @endif
        </div>
    </div>
</div>

<script type="text/javascript" {!! \Helper::cspNonceAttr() !!}>
(function () {
    function initMetaMessengerIndex() {
        var copyBtn = document.getElementById('mm_copy_index_webhook');
        var urlInput = document.getElementById('mm_index_webhook_url');
        if (copyBtn && urlInput) {
            copyBtn.addEventListener('click', function () {
                urlInput.select();
                if (navigator.clipboard && navigator.clipboard.writeText) {
                    navigator.clipboard.writeText(urlInput.value);
                } else {
                    document.execCommand('copy');
                }
                copyBtn.textContent = 'Skopiowano!';
                setTimeout(function () { copyBtn.textContent = 'Kopiuj URL'; }, 1800);
            });
        }

        document.querySelectorAll('.mm-delete-form').forEach(function (form) {
            form.addEventListener('submit', function (e) {
                if (!window.confirm('Czy na pewno usunąć to powiązanie Meta Messenger & IG? Dotychczasowe konwersacje w skrzynce pozostaną nienaruszone.')) {
                    e.preventDefault();
                }
            });
        });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initMetaMessengerIndex);
    } else {
        initMetaMessengerIndex();
    }
})();
</script>
@endsection

<?php

declare(strict_types=1);

namespace Modules\MetaMessenger\Models;

use Illuminate\Contracts\Encryption\DecryptException;
use Illuminate\Database\Eloquent\Model;

class MessengerAccount extends Model
{
    public const CHANNEL_MESSENGER = 105;
    public const CHANNEL_MESSENGER_NAME = 'Messenger';

    public const CHANNEL_INSTAGRAM = 106;
    public const CHANNEL_INSTAGRAM_NAME = 'Instagram';

    protected $table = 'meta_messenger_accounts';

    /**
     * Encrypted secrets (app_secret, page_access_token) are intentionally excluded
     * from mass-assignment and JSON serialization.
     *
     * @var array<int, string>
     */
    protected $fillable = [
        'mailbox_id',
        'name',
        'page_id',
        'ig_account_id',
        'app_id',
        'verify_token',
        'active',
    ];

    /**
     * @var array<int, string>
     */
    protected $hidden = [
        'app_secret',
        'page_access_token',
    ];

    /**
     * @var array<string, string>
     */
    protected $casts = [
        'mailbox_id' => 'integer',
        'active'     => 'boolean',
    ];

    public function setAppSecretPlain(string $plainSecret): void
    {
        $this->attributes['app_secret'] = encrypt($plainSecret);
    }

    public function setPageAccessTokenPlain(string $plainToken): void
    {
        $this->attributes['page_access_token'] = encrypt($plainToken);
    }

    public function getDecryptedAppSecret(): ?string
    {
        $raw = $this->attributes['app_secret'] ?? '';
        if (!is_string($raw) || $raw === '') {
            return null;
        }

        try {
            $decrypted = decrypt($raw);
            return is_string($decrypted) && $decrypted !== '' ? $decrypted : null;
        } catch (DecryptException $e) {
            return null;
        } catch (\Throwable $e) {
            return null;
        }
    }

    public function getDecryptedPageAccessToken(): ?string
    {
        $raw = $this->attributes['page_access_token'] ?? '';
        if (!is_string($raw) || $raw === '') {
            return null;
        }

        try {
            $decrypted = decrypt($raw);
            return is_string($decrypted) && $decrypted !== '' ? $decrypted : null;
        } catch (DecryptException $e) {
            return null;
        } catch (\Throwable $e) {
            return null;
        }
    }

    public function credentialsAreReadable(): bool
    {
        return $this->getDecryptedAppSecret() !== null
            && $this->getDecryptedPageAccessToken() !== null;
    }

    public function getStatusLabel(): string
    {
        if (!$this->credentialsAreReadable()) {
            return 'credentials_broken';
        }
        if (!$this->mailbox) {
            return 'mailbox_unlinked';
        }
        return $this->active ? 'active' : 'inactive';
    }

    public function mailbox()
    {
        return $this->belongsTo(\App\Mailbox::class, 'mailbox_id');
    }

    public function messages()
    {
        return $this->hasMany(MessengerMessage::class, 'account_id');
    }

    public static function channelForPlatform(string $platform): int
    {
        return $platform === MessengerMessage::PLATFORM_INSTAGRAM
            ? self::CHANNEL_INSTAGRAM
            : self::CHANNEL_MESSENGER;
    }

    public static function platformForChannel(int $channel): ?string
    {
        if ($channel === self::CHANNEL_MESSENGER) {
            return MessengerMessage::PLATFORM_MESSENGER;
        }
        if ($channel === self::CHANNEL_INSTAGRAM) {
            return MessengerMessage::PLATFORM_INSTAGRAM;
        }
        return null;
    }
}

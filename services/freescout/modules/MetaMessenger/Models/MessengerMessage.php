<?php

declare(strict_types=1);

namespace Modules\MetaMessenger\Models;

use Illuminate\Database\Eloquent\Model;

class MessengerMessage extends Model
{
    public const PLATFORM_MESSENGER = 'messenger';
    public const PLATFORM_INSTAGRAM = 'instagram';

    public const DIRECTION_IN  = 'in';
    public const DIRECTION_OUT = 'out';

    protected $table = 'meta_messenger_messages';

    /**
     * @var array<int, string>
     */
    protected $fillable = [
        'account_id',
        'conversation_id',
        'thread_id',
        'mid',
        'platform',
        'sender_id',
        'direction',
    ];

    /**
     * @var array<string, string>
     */
    protected $casts = [
        'account_id'      => 'integer',
        'conversation_id' => 'integer',
        'thread_id'       => 'integer',
    ];

    public function account()
    {
        return $this->belongsTo(MessengerAccount::class, 'account_id');
    }

    public function conversation()
    {
        return $this->belongsTo(\App\Conversation::class, 'conversation_id');
    }

    public function thread()
    {
        return $this->belongsTo(\App\Thread::class, 'thread_id');
    }
}

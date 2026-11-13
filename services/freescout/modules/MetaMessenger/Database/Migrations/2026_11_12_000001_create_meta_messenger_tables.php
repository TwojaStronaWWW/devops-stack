<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

class CreateMetaMessengerTables extends Migration
{
    /**
     * Run the migrations.
     *
     * @return void
     */
    public function up()
    {
        if (!Schema::hasTable('meta_messenger_accounts')) {
            Schema::create('meta_messenger_accounts', function (Blueprint $table) {
                $table->increments('id');
                $table->unsignedInteger('mailbox_id')->index();
                $table->string('name', 100);
                $table->string('page_id', 64)->unique();
                $table->string('ig_account_id', 64)->nullable()->index();
                $table->string('app_id', 64)->nullable();
                $table->text('app_secret');
                $table->text('page_access_token');
                $table->string('verify_token', 128)->index();
                $table->boolean('active')->default(true)->index();
                $table->timestamps();
            });
        }

        if (!Schema::hasTable('meta_messenger_messages')) {
            Schema::create('meta_messenger_messages', function (Blueprint $table) {
                $table->bigIncrements('id');
                $table->unsignedInteger('account_id')->index();
                $table->unsignedInteger('conversation_id')->nullable()->index();
                $table->unsignedInteger('thread_id')->nullable()->index();
                $table->string('mid', 191)->unique();
                $table->string('platform', 20)->index(); // 'messenger' | 'instagram'
                $table->string('sender_id', 64)->index();
                $table->string('direction', 8)->index(); // 'in' | 'out'
                $table->timestamps();
            });
        }
    }

    /**
     * Reverse the migrations.
     *
     * @return void
     */
    public function down()
    {
        Schema::dropIfExists('meta_messenger_messages');
        Schema::dropIfExists('meta_messenger_accounts');
    }
}

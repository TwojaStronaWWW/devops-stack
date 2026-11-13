<?php

declare(strict_types=1);

// Admin UI routes (protected by web session, CSRF, and auth + admin check in controller)
Route::group([
    'middleware' => ['web', 'auth'],
    'prefix'     => \Helper::getSubdirectory() . '/meta-messenger',
    'namespace'  => 'Modules\MetaMessenger\Http\Controllers',
], static function (): void {
    Route::get('/settings', 'MetaMessengerController@index')->name('metamessenger.index');
    Route::get('/settings/create', 'MetaMessengerController@create')->name('metamessenger.create');
    Route::post('/settings', 'MetaMessengerController@store')->name('metamessenger.store');
    Route::get('/settings/{id}/edit', 'MetaMessengerController@edit')->name('metamessenger.edit');
    Route::put('/settings/{id}', 'MetaMessengerController@update')->name('metamessenger.update');
    Route::delete('/settings/{id}', 'MetaMessengerController@destroy')->name('metamessenger.destroy');
    Route::post('/settings/{id}/test', 'MetaMessengerController@testConnection')->name('metamessenger.test');
});

// Stateless Meta Webhook endpoint — intentionally outside 'web' group (no session cookie, no CSRF token;
// protected fail-closed via constant-time verify_token & X-Hub-Signature-256 HMAC-SHA256).
Route::group([
    'prefix'    => \Helper::getSubdirectory() . '/meta-messenger',
    'namespace' => 'Modules\MetaMessenger\Http\Controllers',
], static function (): void {
    Route::get('/webhook', 'WebhookController@verify')->name('metamessenger.webhook.verify');
    Route::post('/webhook', 'WebhookController@receive')->name('metamessenger.webhook.receive');
});

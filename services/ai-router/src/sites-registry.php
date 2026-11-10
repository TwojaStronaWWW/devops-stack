<?php
declare(strict_types=1);

/**
 * AI Router — Centralny Rejestr Witryn i Domen (Single Source of Truth)
 *
 * Kanoniczne definicje białych list CORS (Origin), identyfikatorów witryn analitycznych (site_id)
 * oraz wzorca wykluczeń odesłań własnych (Self-Referral) dla wszystkich projektów TwojaStronaWWW.
 */

/**
 * Zwraca kanoniczną listę autoryzowanych domen produkcyjnych HTTPS dla polityki CORS.
 *
 * @return string[]
 */
function aiGetDefaultAllowedOrigins(): array
{
    return [
        'https://katosalsahub.pl',
        'https://www.katosalsahub.pl',
        'https://dancepuls.pl',
        'https://www.dancepuls.pl',
        'https://fuegolingua.pl',
        'https://www.fuegolingua.pl',
        'https://twojastronawww.pl',
        'https://www.twojastronawww.pl',
        'https://raricart.pl',
        'https://www.raricart.pl',
        'https://laclave.pl',
        'https://www.laclave.pl',
        'https://milpasoskatowice.pl',
        'https://www.milpasoskatowice.pl',
        'https://goodmood.dance',
        'https://www.goodmood.dance',
        'https://tanecznakompania.pl',
        'https://www.tanecznakompania.pl',
        'https://radar-p1.pages.dev',
        'https://medicusnoster.pl',
        'https://www.medicusnoster.pl',
        'https://medycyna-regeneracyjna.pl',
        'https://www.medycyna-regeneracyjna.pl',
        'https://krzysztofpoczatek.pl',
        'https://www.krzysztofpoczatek.pl',
        'https://odzyskiwanie.twojastronawww.pl',
        'https://wspolnekamienice.pl',
        'https://www.wspolnekamienice.pl',
    ];
}

/**
 * Zwraca białą listę dozwolonych identyfikatorów witryn (site_id) dla Cookieless Web Analytics & GSC Sync.
 *
 * @return string[]
 */
function aiGetAllowedAnalyticsSites(): array
{
    return [
        'katosalsahub',
        'dancepuls',
        'fuegolingua',
        'twojastronawww',
        'raricart',
        'radar-p1',
        'medicusnoster',
        'medycyna-regeneracyjna',
        'moje-cv',
        'pawel-krzewinski-cv',
        'odzyskiwanie-stron',
        'wspolnekamienice',
    ];
}

/**
 * Zwraca wyrażenie regularne dopasowujące wszystkie własne domeny produkcyjne oraz ruch lokalny (Self-Referral Guard).
 */
function aiGetSelfReferralPattern(): string
{
    return '/(katosalsahub\.pl|dancepuls\.pl|fuegolingua\.pl|twojastronawww\.pl|raricart\.pl|laclave\.pl|milpasoskatowice\.pl|goodmood\.dance|tanecznakompania\.pl|radar-p1\.pages\.dev|medicusnoster\.pl|medycyna-regeneracyjna\.pl|krzysztofpoczatek\.pl|odzyskiwanie\.twojastronawww\.pl|wspolnekamienice\.pl|localhost|127\.0\.0\.1)/i';
}

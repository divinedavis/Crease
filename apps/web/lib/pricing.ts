/**
 * The two numbers the site quotes everywhere, and the band it quotes them in.
 *
 * They were literals in five files — page.tsx twice, order-form.tsx, the area
 * page's prose and its JSON-LD — which is fine right up until one of them
 * changes and four of the five keep quoting the old rate. The trip prices are
 * NOT duplicated here: they live in tiers.ts, mirrored from
 * services/dispatch/src/pricing.ts, and a third copy would defeat the point.
 *
 * The centre point is the middle of the nine Clinton Hill shops in the
 * canvass, not the partner cleaner's doorstep. Structured data is public, and
 * Crease's coverage claim is "three miles of Clinton Hill" — a neighbourhood,
 * which is what this is. Where any one shop stands is that shop's business.
 */
import { SERVICE_RADIUS_MILES } from './coverage';

export const PER_POUND_USD = '2.00';
export const MINIMUM_USD = '20.00';

/** Rendered into prose, so it carries its own punctuation. */
export const PER_POUND_LABEL = `$${PER_POUND_USD}/lb · $${Number(MINIMUM_USD)} minimum`;

export const SERVICE_CENTRE = {
  lat: 40.68903,
  lng: -73.96621,
  name: 'Clinton Hill, Brooklyn',
};

/** Metres, because GeoCircle has no other unit. */
const RADIUS_METRES = Math.round(SERVICE_RADIUS_MILES * 1609.344);

/**
 * The homepage's structured data.
 *
 * A GeoCircle rather than a list of neighbourhood names, because the band is
 * what the address check actually enforces — naming thirty places implies a
 * boundary that follows their edges, and it does not.
 *
 * No address, no opening hours, no aggregateRating. Crease has no premises to
 * publish, no hours a person could turn up during, and no reviews yet; a
 * schema claiming otherwise is the kind that earns a manual action.
 */
export function homeJsonLd() {
  return {
    '@context': 'https://schema.org',
    '@type': 'Service',
    serviceType: 'Wash and fold laundry pickup and delivery',
    name: 'Crease — laundry pickup and delivery in Brooklyn',
    description:
      'A courier collects your laundry from your door, your neighborhood laundromat washes, dries and folds it, and it comes back to you.',
    provider: {
      '@type': 'LocalBusiness',
      name: 'Crease',
      url: 'https://creasenyc.com',
      image: 'https://creasenyc.com/assets/icon.svg',
      areaServed: {
        '@type': 'GeoCircle',
        geoMidpoint: {
          '@type': 'GeoCoordinates',
          latitude: SERVICE_CENTRE.lat,
          longitude: SERVICE_CENTRE.lng,
        },
        geoRadius: RADIUS_METRES,
        description: `Within ${SERVICE_RADIUS_MILES} miles of ${SERVICE_CENTRE.name}`,
      },
    },
    areaServed: {
      '@type': 'GeoCircle',
      geoMidpoint: {
        '@type': 'GeoCoordinates',
        latitude: SERVICE_CENTRE.lat,
        longitude: SERVICE_CENTRE.lng,
      },
      geoRadius: RADIUS_METRES,
    },
    offers: {
      '@type': 'Offer',
      priceCurrency: 'USD',
      description: `Wash and fold, per pound, $${Number(MINIMUM_USD)} minimum`,
      priceSpecification: {
        '@type': 'UnitPriceSpecification',
        price: PER_POUND_USD,
        priceCurrency: 'USD',
        unitCode: 'LBR',
        unitText: 'pound',
        minPrice: MINIMUM_USD,
      },
    },
  };
}

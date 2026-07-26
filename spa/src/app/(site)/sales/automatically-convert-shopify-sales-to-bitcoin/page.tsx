import SalesLanding from '@/components/castle/SalesLanding'

export const metadata = { title: 'Convert Shopify Sales to Bitcoin | QuidMint' }

export default function Page() {
  return (
    <SalesLanding
      merchant="Shopify"
      icon="/castle/images/integrations/icons/shopify-icon.svg"
      verb="sales"
      verbCap="Sales"
    />
  )
}

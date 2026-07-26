import SalesLanding from '@/components/castle/SalesLanding'

export const metadata = { title: 'Convert Square Sales to Bitcoin | QuidMint' }

export default function Page() {
  return (
    <SalesLanding
      merchant="Square"
      icon="/castle/images/integrations/icons/square-icon.svg"
      verb="sales"
      verbCap="Sales"
    />
  )
}

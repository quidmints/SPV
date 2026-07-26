import SalesLanding from '@/components/castle/SalesLanding'

export const metadata = { title: 'Convert PayPal Payments to Bitcoin | QuidMint' }

export default function Page() {
  return (
    <SalesLanding
      merchant="PayPal"
      icon="/castle/images/integrations/icons/paypal-icon.svg"
      verb="payments"
      verbCap="Payments"
    />
  )
}

import SalesLanding from '@/components/castle/SalesLanding'

export const metadata = { title: 'Convert Stripe Payments to Bitcoin | QuidMint' }

export default function Page() {
  return (
    <SalesLanding
      merchant="Stripe"
      icon="/castle/images/integrations/icons/stripe-icon.svg"
      verb="payments"
      verbCap="Payments"
    />
  )
}

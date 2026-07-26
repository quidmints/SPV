import SiteHeader from '@/components/castle/SiteHeader'
import SiteFooter from '@/components/castle/SiteFooter'

export const metadata = { title: 'Privacy Policy | QuidMint' }

export default function Page() {
  return (
    <div className="flex min-h-screen flex-col">
      <SiteHeader />
      <main className="flex-1">
        <div className="px-2 sm:px-3 pt-2 sm:pt-3 pb-4 sm:pb-6 bg-white">
          <section
            data-track-location="hero"
            className="relative overflow-hidden rounded-[20px] pt-[140px] pb-[64px]"
            style={{
              border: '1px solid rgba(9, 9, 11, 0.12)',
              boxShadow:
                'rgba(2, 8, 20, 0.1) 0px 16px 32px -14px, rgba(2, 8, 20, 0.06) 0px 6px 14px -6px, rgba(2, 8, 20, 0.04) 0px 1px 2px',
            }}
          >
            <div
              className="absolute inset-0 pointer-events-none"
              style={{ background: 'linear-gradient(rgb(255, 255, 255) 0%, rgb(245, 247, 250) 100%)' }}
            />
            <div
              className="absolute inset-0 pointer-events-none"
              style={{
                maskImage:
                  'linear-gradient(transparent 0%, rgba(0, 0, 0, 0.15) 35%, rgb(0, 0, 0) 100%)',
              }}
            >
              <div
                className="pointer-events-none absolute inset-0 h-full w-full overflow-hidden opacity-60"
                aria-hidden="true"
              >
                <div
                  className="absolute inset-0 transform-gpu"
                  style={{
                    backgroundImage:
                      'url("data:image/svg+xml;utf8,%0A%20%20%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%20width%3D%2240%22%20height%3D%2240%22%20viewBox%3D%220%200%2040%2040%22%20fill%3D%22none%22%3E%0A%20%20%20%20%3Cpath%20d%3D%22M20%2014V26M14%2020H26%22%20stroke%3D%22%23E5E7EB%22%20stroke-width%3D%222%22%20stroke-linecap%3D%22round%22%20%2F%3E%0A%20%20%3C%2Fsvg%3E%0A")',
                    backgroundSize: '40px 40px',
                    opacity: 1,
                  }}
                />
              </div>
            </div>
            <div className="container relative mx-auto px-4 sm:px-8">
              <div className="mx-auto max-w-4xl text-center">
                <div>
                  <div className="mb-3 inline-flex items-center gap-2 rounded-full px-4 py-1.5 text-sm font-medium bg-castle-blue/10 text-castle-blue">
                    Legal
                  </div>
                </div>
                <h1 className="mb-3 text-[36px] md:text-[56px] lg:text-[64px] font-normal tracking-[-0.05em] leading-[1] text-[#09090b] font-px-grotesk">
                  Privacy Policy
                </h1>
                <p className="whitespace-pre-wrap mb-8 text-[18px] md:text-[20px] text-[#525866] leading-[1.4] max-w-2xl mx-auto font-normal">
                  How QuidMint collects, uses, and protects your information.
                </p>
              </div>
            </div>
          </section>
        </div>
        <section className="pt-6 pb-12">
          <div className="container mx-auto px-4">
            <article className="max-w-3xl mx-auto">
              <div className="prose prose-lg max-w-none prose-headings:text-[#09090b] prose-headings:font-semibold prose-h2:text-2xl prose-h2:mt-10 prose-h2:mb-4 prose-h3:text-xl prose-h3:mt-8 prose-h3:mb-3 prose-h4:text-lg prose-h4:mt-6 prose-h4:mb-2 prose-p:text-[#525866] prose-p:leading-relaxed prose-li:text-[#525866] prose-strong:text-[#09090b] prose-a:text-castle-blue prose-a:no-underline hover:prose-a:underline prose-code:bg-gray-100 prose-code:px-1.5 prose-code:py-0.5 prose-code:rounded prose-code:text-sm prose-code:font-normal prose-code:before:content-none prose-code:after:content-none prose-pre:bg-gray-900 prose-pre:text-gray-100 prose-table:border-collapse prose-th:border prose-th:border-gray-200 prose-th:bg-gray-50 prose-th:px-4 prose-th:py-2 prose-th:text-left prose-th:font-semibold prose-td:border prose-td:border-gray-200 prose-td:px-4 prose-td:py-2 prose-img:rounded-lg prose-img:shadow-md">
                <p>
                  ORQESTRA, INC.{'\n'}
                  PRIVACY POLICY{'\n'}
                  Last updated August 19, 2025
                </p>
                <p>
                  This privacy notice for Orqestra, Inc. (dba QuidMint) (&ldquo;QuidMint&rdquo;, &ldquo;we,&rdquo; &ldquo;us,&rdquo; or &ldquo;our&rdquo;), describes how and why we might collect, store, use, and/or share (&ldquo;process&rdquo;) your information when you visit our our web-based platform at savewithcastle.com, mobile applications, and technical interfaces (collectively &ldquo;Services&rdquo;). To learn about our collection, use and disclosure of cookies, please visit our Cookie Notice.
                </p>
                <h2>1. WHAT INFORMATION WE COLLECT</h2>
                <p>
                  Personal information you disclose to us. We collect personal information that you voluntarily provide to us when you register for the Services, express an interest in obtaining information about us or our products and Services, when you participate in activities for the Services, or otherwise when you contact us.
                </p>
                <p>
                  Personal Information Provided by You. The personal information that we collect depends on the context of your interactions with us and the Services, the choices you make, and the products and features you use. The personal information we collect may include the following:
                </p>
                <ul>
                  <li>debit/credit card numbers</li>
                  <li>billing addresses</li>
                  <li>contact or authentication data</li>
                  <li>contact preferences</li>
                  <li>passwords</li>
                  <li>usernames</li>
                  <li>job titles</li>
                  <li>mailing addresses</li>
                  <li>email addresses</li>
                  <li>phone numbers</li>
                  <li>names, photo and identification documents</li>
                </ul>
                <p>
                  Payment Data. We may collect data necessary to process your payment if you make purchases, receiving or providing payment, or conducting commerce through our Services, such as your payment instrument number, and the security code associated with your payment instrument.
                </p>
                <p>
                  Social Media Login Data. We may provide you with the option to register with us using your existing external account details, like your Google, Microsoft, Facebook, X, or any other social media accounts. This information is primarily needed to maintain the security and operation of our Services, improve, maintain and provide our Services, for troubleshooting, and for our internal analytics and reporting purposes.
                </p>
                <p>
                  Information automatically collected{'\n'}
                  We may automatically collect certain information when you visit, use, or navigate the Services. This information may include device and usage information, such as your IP address, browser and device characteristics, operating system, language preferences, referring URLs, device name, country, location, information about how and when you use our Services, and other technical information. This information is primarily needed to maintain the security and operation of our Services, improve, maintain and provide our Services, and for our internal analytics and reporting purposes.
                </p>
                <p>We may also collect information through cookies and similar technologies. The information we collect includes:</p>
                <ul>
                  <li>
                    Log and Usage Data. Log and usage data is service-related, diagnostic, usage, and performance information our servers automatically collect when you access or use our Services and which we record in log files. Depending on how you interact with us, this log data may include your IP address, device information, browser type, settings and information about your activity in the Services including, but not limited to, the date/time stamps associated with your usage, pages and files viewed, searches, actions you take such as which features you use, device event information such as system activity, error reports (sometimes called &ldquo;crash dumps&rdquo;), and hardware settings.
                  </li>
                  <li>
                    Device Data. We may collect device data such as information about your computer, phone, tablet, or other device you use to access the Services. Depending on the device used, this device data may include information such as your IP address (or proxy server), device and application identification numbers, location, browser type, hardware model, Internet service provider and/or mobile carrier, operating system, and system configuration information.
                  </li>
                  <li>
                    Location Data. We may collect location data such as information about your device&apos;s location, which can be either precise or imprecise. How much information we collect depends on the type and settings of the device you use to access the Services. For example, we may use GPS and other technologies to collect geolocation data that tells us your current location (based on your IP address), but only when necessary to provide certain location-based Services.
                  </li>
                  <li>
                    Aggregate Information. We may collect statistical information about how both unregistered and registered users, collectively, use the Services. Some of this information is derived from personal information. This statistical data is not personal information and cannot be tied back to you, your account, or your web browser.
                  </li>
                </ul>
                <p>
                  We do not aim to collect sensitive personal information (e.g., information related to racial or ethnic origin, political opinions, religion or other beliefs, health, biometric data, criminal background, or trade union membership) and ask that you do not provide us with any such information.
                </p>
                <p>
                  When we process your personal information because this is necessary for our, or someone else&apos;s legitimate interests, we may carry out a balancing test to document our interests, to consider what the impact of the processing is on individuals, and to determine if those interests outweigh our interests in the processing taking place.
                </p>
                <h2>2. HOW WE PROCESS INFORMATION</h2>
                <p>We process your personal information for a variety of reasons, depending on how you interact with our Services, including:</p>
                <ul>
                  <li>To facilitate account creation and authentication and otherwise manage user accounts. We may process your information so you can create and log in to your account, as well as keep your account in working order. In order to activate your account, we need to collect information to verify your identity or to comply with regulations.</li>
                  <li>To deliver and facilitate the delivery of Services to the user. We may process your information to provide you with the requested service.</li>
                  <li>To respond to user inquiries/offer support to users. We may process your information to respond to your inquiries and solve any potential issues you might have with the requested service.</li>
                  <li>To send administrative information to you. We may process your information to send you details about our products and Services, changes to our terms and policies, and other similar information.</li>
                  <li>To fulfill and manage your orders. We may process your information to fulfill and manage your orders, payments, returns, and exchanges made through the Services.</li>
                  <li>To enable user-to-user communications. We may process your information if you choose to use any of our offerings that allow for communication with another user.</li>
                  <li>To request feedback. We may process your information when necessary to request feedback and to contact you about your use of our Services.</li>
                  <li>To send you marketing and promotional communications. We may process the personal information you send to us for our marketing purposes in the event this is in accordance with your marketing preferences. You can opt out of our marketing emails at any time.</li>
                  <li>To deliver targeted advertising to you. We may process your information to develop and display personalized content and advertising tailored to your interests, location, and more. Please note that we do not sell personal information or share personal information for targeted or cross-contextual advertising purposes.</li>
                  <li>To protect our Services. We may process your information as part of our efforts to keep our Services safe and secure, including fraud monitoring and prevention.</li>
                  <li>To identify usage trends. We may process information about how you use our Services to better understand how they are being used so we can improve them.</li>
                  <li>To determine the effectiveness of our marketing and promotional campaigns. We may process your information to better understand how to provide marketing and promotional campaigns that are most relevant to you.</li>
                  <li>To save or protect an individual&apos;s vital interest. We may process your information when necessary to save or protect an individual&apos;s vital interest, such as to prevent harm.</li>
                </ul>
                <h2>3. WHAT LEGAL BASES WE RELY ON TO PROCESS INFORMATION</h2>
                <p>If you are located in the EU or UK, this section applies to you.</p>
                <p>We are the controllers of your personal information as described in this Privacy Policy, unless otherwise specified.</p>
                <p>The General Data Protection Regulation (GDPR) and UK GDPR require us to explain the valid legal bases we rely on in order to process your personal information. As such, we may rely on the following legal bases to process your personal information:</p>
                <ul>
                  <li>Consent. We may process your information in the event you have given us permission (i.e., consent) to use your personal information for a specific purpose. You can withdraw your consent at any time.</li>
                  <li>Performance of a Contract. We may process your personal information when we believe it is necessary to fulfill our contractual obligations to you, including providing, improving or securing our Services or at your request prior to entering into a contract with you or a third party to provide you the Services.</li>
                  <li>
                    Legitimate Interests. We may process your information when we believe it is reasonably necessary to achieve our legitimate business interests and those interests do not outweigh your interests and fundamental rights and freedoms. For example, we may process your personal information for some of the purposes described in order to:
                    <ul>
                      <li>Send users information about special offers and discounts on our products and Services;</li>
                      <li>Develop and display personalized and relevant advertising content for our users;</li>
                      <li>Analyze how our Services are used so we can improve them to engage and retain users;</li>
                      <li>Support our marketing activities;</li>
                      <li>Diagnose problems and/or prevent fraudulent activities; and</li>
                      <li>Understand how our users use our products and Services so we can improve user experience.</li>
                    </ul>
                  </li>
                  <li>Legal Obligations. We may process your information where we believe it is necessary for compliance with our legal obligations, such as to cooperate with a law enforcement body or regulatory agency, exercise or defend our legal rights, or disclose your information as evidence in litigation in which we are involved.</li>
                  <li>Vital Interests. We may process your information where we believe it is necessary to protect your vital interests or the vital interests of a third party, such as in situations involving potential threats to the safety of any person.</li>
                </ul>
                <h2>4. WHEN AND WITH WHOM WE SHARE PERSONAL INFORMATION</h2>
                <p>Vendors, Consultants, and Other Third-Party Service Providers. We may share your data with third-party vendors, service providers, contractors, or agents (&ldquo;third parties&rdquo;) who perform services for us or on our behalf and require access to such information to do that work. We have contracts in place with our third parties, which are designed to help safeguard your personal information. The categories of third parties we may share personal information with are as follows:</p>
                <ul>
                  <li>Cloud Computing Services</li>
                  <li>Communication &amp; Collaboration Tools</li>
                  <li>Data Analytics Services</li>
                  <li>Data Storage Service Providers</li>
                  <li>Finance &amp; Accounting Tools</li>
                  <li>Payment Processors</li>
                  <li>Sales &amp; Marketing Tools</li>
                  <li>User Account Registration &amp; Authentication Services</li>
                  <li>Affiliate Marketing Programs</li>
                  <li>Performance Monitoring Tools</li>
                  <li>Product Engineering &amp; Design Tools</li>
                  <li>Retargeting Platforms</li>
                  <li>Social Networks</li>
                  <li>Testing Tools</li>
                  <li>Website Hosting Service Providers</li>
                </ul>
                <p>We also may need to share your personal information in the following situations:</p>
                <ul>
                  <li>Business Transfers. We may share or transfer your information in connection with or during negotiations of any merger, sale of company assets, financing, or acquisition of all or a portion of our business to another company.</li>
                  <li>Business Partners. We may share your information with our business partners to offer you certain products, services, or promotions.</li>
                </ul>
                <h2>5. THIRD-PARTY WEBSITES?</h2>
                <p>
                  The Services may link to third-party websites, online services, or mobile applications and/or contain advertisements from third parties that are not affiliated with us and which may link to other websites, services, or applications. Accordingly, we do not make any guarantee regarding any such third parties, and we will not be liable for any loss or damage caused by the use of such third-party websites, services, or applications. The inclusion of a link to a third-party website, service, or application does not imply an endorsement by us. We cannot guarantee the safety and privacy of data you provide to any third parties. Any data collected by third parties is not covered by this privacy notice. We are not responsible for the content or privacy and security practices and policies of any third parties, including other websites, services, or applications that may be linked to or from the Services. You should review the policies of such third parties and contact them directly to respond to your questions.
                </p>
                <h2>6. DIGITAL ASSETS &amp; BLOCKCHAIN</h2>
                <p>
                  Your use of digital assets may be recorded on a public blockchain. Public blockchains are distributed ledgers, intended to immutably record transactions across wide networks of computer systems. Many blockchains are open to forensic analysis which can lead to re-identification of transacting individuals and the revelation of personal data, especially when blockchain data is combined with other data.
                </p>
                <p>
                  As blockchains are decentralized or third-party networks which are not controlled or operated by us, we are not able to exercise any of your applicable privacy rights to personal data on such networks.
                </p>
                <h2>7. SOCIAL LOGINS</h2>
                <p>
                  Our Services offer you the ability to register and log in using your third-party email or social media account details (like your Google, Microsoft, Facebook, or X logins). Where you choose to do this, we will receive certain profile information about you from your social media provider. The profile information we receive may vary depending on the social media provider concerned, but will often include your name, email address, friends list, and profile picture, as well as other information you choose to make public on such a social media platform.
                </p>
                <p>
                  We will use the information we receive only for the purposes that are described in this privacy notice or that are otherwise made clear to you on the relevant Services. Please note that we do not control, and are not responsible for, other uses of your personal information by your third-party social media provider. We recommend that you review their privacy notice to understand how they collect, use, and share your personal information, and how you can set your privacy preferences on their sites and apps.
                </p>
                <h2>8. INTERNATIONAL TRANSFERS</h2>
                <p>
                  Our servers are located in the United States. If you are accessing our Services from outside the United States, please be aware that your information may be transferred to, stored, and processed by us in our facilities and by those third parties in the United States, and other countries.
                </p>
                <p>
                  We use service providers that may be involved in processing personal information as listed on our subprocessors page. These companies either participate in the EU-US Data Privacy Framework, the Swiss-US Data Privacy Framework and the UK extension to the EU-US Data Privacy Framework, which offer adequate protection for European personal information; or we have standard contractual clauses in place with them.
                </p>
                <h2>9. RETENTION OF PERSONAL INFORMATION</h2>
                <p>We retain your personal information where we have an ongoing legitimate business need to do so. In certain circumstances, we will retain your information for legal reasons after our contractual relationship has ended. The specific retention periods depend on the nature of the information and why it is collected and processed and the nature of the legal requirement. For example, we may retain your personal information:</p>
                <ul>
                  <li>When we have a legal obligation to do so (e.g., if we receive a court order, we would retain your information for longer than our usual retention periods);</li>
                  <li>To address and resolve requests and complaints (e.g., if there is an ongoing complaint about or from you);</li>
                  <li>To protect the safety, security, and integrity of our business and the Service, as well as to protect our rights and property and those of others (e.g., if we detect misuse of our Service or otherwise detect unusual activity on your account or in your interactions with us); and</li>
                  <li>For litigation, regulatory or other legal matters (e.g., we would retain your information if there was an ongoing legal claim and the information was relevant to the claim, or there is an investigation by the U.S. Department of the Treasury&apos;s Office of Foreign Assets Control (&ldquo;OFAC&rdquo;) that we may need to participate in).</li>
                </ul>
                <h2>10. SAFETY &amp; SECURITY</h2>
                <p>
                  We have implemented appropriate and reasonable technical and organizational security measures designed to protect the security of any personal information we process. However, despite our safeguards and efforts to secure your information, no electronic transmission over the Internet or information storage technology can be guaranteed to be 100% secure, so we cannot promise or guarantee that hackers, cybercriminals, or other unauthorized third parties will not be able to defeat our security and improperly collect, access, steal, or modify your information. Although we will do our best to protect your personal information, transmission of personal information to and from our Services is at your own risk. You should only access the Services within a secure environment.
                </p>
                <h2>11. GDPR PRIVACY RIGHTS</h2>
                <p>
                  In some regions (like the EEA, UK, and Switzerland), you have certain rights under applicable data protection laws. These may include the right (i) to request access and obtain a copy of your personal information, (ii) to request rectification or erasure; (iii) to restrict the processing of your personal information; (vi) if applicable, to data portability; and (vii) not to be subject to automated decision-making. In certain circumstances, you may also have the right to object to the processing of your personal information. You can make such a request by contacting us using the contact details provided below.
                </p>
                <p>
                  If you are located in the EEA or UK and you believe we are unlawfully processing your personal information, you also have the right to complain to your Member State data protection authority or UK data protection authority.
                </p>
                <p>If you are located in Switzerland, you may contact the Federal Data Protection and Information Commissioner.</p>
                <p>
                  Withdrawing your consent: If we are relying on your consent to process your personal information, which may be express and/or implied consent depending on the applicable law, you have the right to withdraw your consent at any time. You can withdraw your consent at any time by contacting us by using the contact details provided below. However, please note that this will not affect the lawfulness of the processing before its withdrawal, nor when applicable law allows, will it affect the processing of your personal information conducted in reliance on lawful processing grounds other than consent.
                </p>
                <p>
                  Opting out of marketing and promotional communications: You can unsubscribe from our marketing and promotional communications at any time by clicking on the unsubscribe link in the emails that we send, replying &ldquo;STOP&rdquo; or &ldquo;UNSUBSCRIBE&rdquo; to the SMS messages that we send, or by contacting us using the details provided below. You will then be removed from the marketing lists. However, we may still communicate with you &mdash; for example, to send you service-related messages that are necessary for the administration and use of your account, to respond to service requests, or for other non-marketing purposes.
                </p>
                <h2>12. CALIFORNIA RESIDENTS PRIVACY RIGHTS</h2>
                <p>
                  Under California Civil Code Section 1798 (&ldquo;California&apos;s Shine the Light&rdquo;), California residents with an established business relationship with us can request information once a year about sharing their Personal Data with third parties for the third parties&apos; direct marketing purposes. After thorough analysis, we have determined that we are exempt from the California Consumer Privacy Act of 2018, and the later, California Privacy Rights Act of 2020 (collectively, &ldquo;CCPA&rdquo;).
                </p>
                <p>
                  If you&apos;d like to request more information under the California Shine the Light law or other laws, and if you are a California resident, you can contact us using the contact information provided below.
                </p>
                <h2>13. NEVADA PRIVACY RIGHTS</h2>
                <p>
                  If you are a resident of Nevada, you have the right to opt-out of the sale of certain Personal Data to third parties who intend to license or sell that Personal Data. You can exercise this right by contacting us as described below with the subject line &ldquo;Nevada Do Not Sell Request&rdquo; and providing us with your name and the email address associated with your account. Please note that we do not currently sell your Personal Data as sales are defined in Nevada Revised Statutes Chapter 603A. If you have any questions, please contact us as set forth below.
                </p>
                <h2>14. DO-NOT-TRACK</h2>
                <p>
                  Most web browsers and some mobile operating systems and mobile applications include a Do-Not-Track (&ldquo;DNT&rdquo;) feature or setting you can activate to signal your privacy preference not to have data about your online browsing activities monitored and collected. At this stage, no uniform technology standard for recognizing and implementing DNT signals has been finalized. As such, we do not currently respond to DNT browser signals or any other mechanism that automatically communicates your choice not to be tracked online. If a standard for online tracking is adopted that we must follow in the future, we will inform you about that practice in a revised version of this privacy notice.
                </p>
                <h2>15. UPDATES</h2>
                <p>
                  We may update this privacy notice from time to time. The updated version will be indicated by an updated &ldquo;Revised&rdquo; date and the updated version will be effective as soon as it is accessible. We encourage you to review this privacy notice frequently to be informed of how we are protecting your information.
                </p>
                <h2>16. CONTACT US</h2>
                <p>
                  If you have questions or comments about this notice, you may contact Orqestra Inc by email at{' '}
                  <a href="mailto:hello@savewithcastle.com">hello@savewithcastle.com</a> or contact us by post at:
                </p>
                <p>
                  Orqestra Inc{'\n'}
                  150 Alhambra Cir 10th Floor Coral Gables FL 33134
                </p>
              </div>
            </article>
          </div>
        </section>
      </main>
      <SiteFooter />
    </div>
  )
}

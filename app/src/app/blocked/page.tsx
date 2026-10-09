export const metadata = { title: "Not available - Holdcredit" };

export default function Blocked() {
  return (
    <div className="prose">
      <h1>Not available in your region</h1>
      <p className="sub">
        This interface is not offered in your jurisdiction. Tokenized stocks are restricted in several countries,
        including the United States.
      </p>
      <p>
        <a href="/risk">Read the risk disclosure</a>
      </p>
    </div>
  );
}
